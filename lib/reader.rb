# Authorization::Reader

require File.dirname(__FILE__) + '/authorization.rb'

module Authorization
  # Parses an authorization configuration file in the authorization DSL and
  # constructs a data model of its contents.
  # 
  # For examples and the modelled data model, see the 
  # README[link:files/README.html].
  #
  # Also, see 
  # * AuthorizationRulesReader#role,
  # * AuthorizationRulesReader#includes,
  # * AuthorizationRulesReader#title,
  # * AuthorizationRulesReader#description,
  # * AuthorizationRulesReader#has_permission_on,
  # * AuthorizationRulesReader#to,
  # * AuthorizationRulesReader#if_attribute,
  # * AuthorizationRulesReader#contains,
  # * AuthorizationRulesReader#is,
  # * PrivilegesReader#privilege and
  # * PrivilegesReader#includes
  # for details.
  #
  module Reader
    # Signals errors that occur while reading and parsing an authorization DSL
    class DSLError < Exception; end
    # Signals errors in the syntax of an authorization DSL.
    class DSLSyntaxError < DSLError; end
    
    # Top-level reader, parses the methods +privileges+ and +authorization+.
    # +authorization+ takes a block with authorization rules as described in
    # AuthorizationRulesReader.  The block to +privileges+ defines privilege
    # hierarchies, as described in PrivilegesReader.
    #
    class DSLReader
      attr_reader :privileges_reader, :auth_rules_reader # :nodoc:

      def initialize ()
        @privileges_reader = PrivilegesReader.new
        @auth_rules_reader = AuthorizationRulesReader.new
      end

      # Parses a authorization DSL specification from the string given
      # in +dsl_data+.  Raises DSLSyntaxError if errors occur on parsing.
      def parse (dsl_data, file_name = nil)
        if file_name
          DSLMethods.new(self).instance_eval(dsl_data, file_name)
        else
          DSLMethods.new(self).instance_eval(dsl_data)
        end
      rescue SyntaxError, NoMethodError, NameError => e
        raise DSLSyntaxError, "Illegal DSL syntax: #{e}"
      end

      # Loads and parses a DSL from the given file name.
      def self.load (dsl_file)
        # TODO cache reader in production mode?
        reader = new
        reader.parse(File.read(dsl_file), dsl_file)
        reader
      end

      # DSL methods
      class DSLMethods # :nodoc:
        def initialize (parent)
          @parent = parent
        end

        def privileges (&block)
          @parent.privileges_reader.instance_eval(&block)
        end

        def contexts (&block)
          # Not implemented
        end

        def authorization (&block)
          @parent.auth_rules_reader.instance_eval(&block)
        end
      end
    end

    # The PrivilegeReader handles the part of the authorization DSL in
    # a +privileges+ block.  Here, privilege hierarchies are defined.
    class PrivilegesReader
      # TODO handle privileges with separated context
      attr_reader :privileges, :privilege_hierarchy # :nodoc:

      def initialize # :nodoc:
        @current_priv = nil
        @current_context = nil
        @privileges = []
        # {priv => [[priv,ctx], ...]}
        @privilege_hierarchy = {}
      end

      def append_privilege (priv) # :nodoc:
        @privileges << priv unless @privileges.include?(priv)
      end

      # Defines part of a privilege hierarchy.  For the given +privilege+,
      # included privileges may be defined in the block (through includes)
      # or as option :+includes+.  If the optional context is given,
      # the privilege hierarchy is limited to that context.
      #
      def privilege (privilege, context = nil, options = {}, &block)
        if context.is_a?(Hash)
          options = context
          context = nil
        end
        @current_priv = privilege
        @current_context = context
        append_privilege privilege
        instance_eval(&block) if block
        includes(*options[:includes]) if options[:includes]
      ensure
        @current_priv = nil
        @current_context = nil
      end

      # Specifies +privileges+ that are to be assigned as lower ones.  Only to
      # be used inside a privilege block.
      def includes (*privileges)
        raise DSLError, "includes only in privilege block" if @current_priv.nil?
        privileges.each do |priv|
          append_privilege priv
          @privilege_hierarchy[@current_priv] ||= []
          @privilege_hierarchy[@current_priv] << [priv, @current_context]
        end
      end
    end

    class AuthorizationRulesReader
      attr_reader :roles, :role_hierarchy, :auth_rules,
        :role_descriptions, :role_titles # :nodoc:

      def initialize # :nodoc:
        @current_role = nil
        @current_rule = nil
        @roles = []
        # higher_role => [lower_roles]
        @role_hierarchy = {}
        @role_titles = {}
        @role_descriptions = {}
        @auth_rules = []
      end

      def append_role (role, options = {}) # :nodoc:
        @roles << role unless @roles.include? role
        @role_titles[role] = options[:title] if options[:title]
        @role_descriptions[role] = options[:description] if options[:description]
      end

      # Defines the authorization rules for the given +role+ in the
      # following block.
      #   role :admin do
      #     has_permissions_on ...
      #   end
      #
      def role (role, options = {}, &block)
        append_role role, options
        @current_role = role
        yield
      ensure
        @current_role = nil
      end

      # Roles may inherit all the rights from subroles.  The given +roles+
      # become subroles of the current block's role.
      #   role :admin do
      #     includes :user
      #     has_permission_on :employees, :to => [:update, :create]
      #   end
      #   role :user do
      #     has_permission_on :employees, :to => :read
      #   end
      #
      def includes (*roles)
        raise DSLError, "includes only in role blocks" if @current_role.nil?
        @role_hierarchy[@current_role] ||= []
        @role_hierarchy[@current_role] += roles.flatten
      end
      
      # Allows the definition of privileges to be allowed for the current role,
      # either in a has_permission_on block or directly in one call.
      #   role :admin
      #     has_permission_on :employees, :to => :read
      #     has_permission_on [:employees, :orders], :to => :read
      #     has_permission_on :employees do
      #       to :create
      #       if_attribute ...
      #     end
      #     has_permission_on :employees, :to => :delete do
      #       if_attribute ...
      #     end
      #   end
      # The block form allows to describe restrictions on the permissions
      # using if_attribute.  Multiple has_permission_on statements are
      # OR'ed when evaluating the permissions.  Also, multiple if_attribute
      # statements in one block are OR'ed.
      # 
      # Available options
      # [:+to+]
      #   A symbol or an array of symbols representing the privileges that
      #   should be granted in this statement.
      #
      def has_permission_on (context, options = {}, &block)
        raise DSLError, "has_permission_on only allowed in role blocks" if @current_role.nil?
        options = {:to => []}.merge(options)
        
        privs = options[:to] 
        privs = [privs] unless privs.is_a?(Array)
        raise DSLError, "has_permission_on either needs a block or :to option" if !block_given? and privs.empty?
        
        rule = AuthorizationRule.new(@current_role, privs, context)
        @auth_rules << rule
        if block_given?
          @current_rule = rule
          yield
          # TODO ensure?
          @current_rule = nil
        end
      end
      
      # Sets a description for the current role.  E.g.
      #   role :admin
      #     description "To be assigned to administrative personnel"
      #     has_permission_on ...
      #   end
      def description (text)
        raise DSLError, "description only allowed in role blocks" if @current_role.nil?
        role_descriptions[@current_role] = text
      end
      
      # Sets a human-readable title for the current role.  E.g.
      #   role :admin
      #     title "Administrator"
      #     has_permission_on ...
      #   end
      def title (text)
        raise DSLError, "title only allowed in role blocks" if @current_role.nil?
        role_titles[@current_role] = text
      end
      
      # Used in a has_permission_on block, to may be used to specify privileges
      # to be assigned to the current role under the conditions specified in
      # the current block.
      #   role :admin
      #     has_permission_on :employees do
      #       to :create, :read, :update, :delete
      #     end
      #   end
      def to (*privs)
        raise DSLError, "to only allowed in has_permission_on blocks" if @current_rule.nil?
        @current_rule.append_privileges(privs)
      end

      # In a has_permission_on block, if_attribute specifies conditions
      # of dynamic parameters that have to be met for the user to meet the
      # privileges in this block.  Conditions are evaluated on the context
      # object.  Thus, the following allows CRUD for branch admins only on 
      # employees that belong to the same branch as the current user.
      #   role :branch_admin
      #     has_permission_on :employees do
      #       to :create, :read, :update, :delete
      #       if_attribute :branch => is { user.branch }
      #     end
      #   end
      # In this case, is is the operator for evaluating the condition.  Another
      # operator is contains for collections.  In the block supplied to the
      # operator, +user+ specifies the current user for whom the condition
      # is evaluated.
      # 
      # Conditions may be nested:
      #   role :company_admin
      #     has_permission_on :employees do
      #       to :create, :read, :update, :delete
      #       if_attribute :branch => { :company => is {user.branch.company} }
      #     end
      #   end
      # 
      # Multiple if_attribute statements are OR'ed.
      def if_attribute (attr_conditions_hash)
        raise DSLError, "if_attribute only in has_permission blocks" if @current_rule.nil?
        parse_attribute_conditions_hash!(attr_conditions_hash)
        @current_rule.append_attribute Attribute.new(attr_conditions_hash)
      end
      
      # In an if_attribute statement, is says that the value has to be exactly
      # met by the if_attribute attribute.  For the block, see if_attribute.
      def is (&block)
        [:is, block]
      end
      
      # In an if_attribute statement, contains says that the value has to be
      # part of the collection specified by the if_attribute attribute.
      # For the block, see if_attribute.
      def contains (&block)
        [:contains, block]
      end
      
      private
      def parse_attribute_conditions_hash! (hash)
        merge_hash = {}
        hash.each do |key, value|
          if value.is_a?(Hash)
            parse_attribute_conditions_hash!(value)
          elsif !value.is_a?(Array)
            merge_hash[key] = [:is, lambda { value }]
          end
        end
        hash.merge!(merge_hash)
      end
    end
  end
end
