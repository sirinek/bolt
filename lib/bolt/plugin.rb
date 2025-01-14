# frozen_string_literal: true

require 'bolt/inventory'
require 'bolt/executor'
require 'bolt/module'
require 'bolt/pal'
require 'bolt/plugin/puppetdb'

module Bolt
  class Plugin
    KNOWN_HOOKS = %i[
      puppet_library
      resolve_reference
      secret_encrypt
      secret_decrypt
      secret_createkeys
      validate_resolve_reference
    ].freeze

    class PluginError < Bolt::Error
      class ExecutionError < PluginError
        def initialize(msg, plugin_name, location)
          mess = "Error executing plugin #{plugin_name} from #{location}: #{msg}"
          super(mess, 'bolt/plugin-error')
        end
      end

      class Unknown < PluginError
        def initialize(plugin_name)
          super("Unknown plugin: '#{plugin_name}'", 'bolt/unknown-plugin')
        end
      end

      class UnsupportedHook < PluginError
        def initialize(plugin_name, hook)
          super("Plugin #{plugin_name} does not support #{hook}", 'bolt/unsupported-hook')
        end
      end
    end

    class PluginContext
      def initialize(config, pal)
        @pal = pal
        @config = config
      end

      def serial_executor
        @serial_executor ||= Bolt::Executor.new(1)
      end
      private :serial_executor

      def empty_inventory
        @empty_inventory ||= Bolt::Inventory.new({}, @config)
      end
      private :empty_inventory

      def with_a_compiler
        # If we're already inside a pal compiler block use that compiler
        # This may blow up if you try to load a task in catalog pal. Should we
        # guard against that?
        compiler = nil
        if defined?(Puppet)
          begin
            compiler = Puppet.lookup(:pal_compiler)
          rescue Puppet::Context::UndefinedBindingError; end # rubocop:disable Lint/HandleExceptions
        end

        if compiler
          yield compiler
        else
          @pal.in_bolt_compiler do |temp_compiler|
            yield temp_compiler
          end
        end
      end
      private :with_a_compiler

      def get_validated_task(task_name, params = nil)
        with_a_compiler do |compiler|
          tasksig = compiler.task_signature(task_name)

          raise Bolt::Error.unknown_task(task_name) unless tasksig

          Bolt::Task::Run.validate_params(tasksig, params) if params
          Bolt::Task.new(tasksig.task_hash)
        end
      end

      def validate_params(task_name, params)
        with_a_compiler do |compiler|
          tasksig = compiler.task_signature(task_name)

          raise Bolt::Error.new("#{task_name} could not be found", 'bolt/plugin-error') unless tasksig

          Bolt::Task::Run.validate_params(tasksig, params)
        end
        nil
      end

      # By passing `_` keys in params the caller can send metaparams directly to the task
      # _catch_errors must be passed as an executor option not a param
      def run_local_task(task, params, options)
        # Make sure we're in a compiler to use the sensitive type
        with_a_compiler do |_comp|
          params = Bolt::Task::Run.wrap_sensitive(task, params)
          Bolt::Task::Run.run_task(
            task,
            empty_inventory.get_targets('localhost'),
            params,
            options,
            serial_executor
          )
        end
      end

      def boltdir
        @config.boltdir.path
      end
    end

    def self.setup(config, pal, pdb_client, analytics)
      plugins = new(config, pal, analytics)
      # PDB is special do we want to expose the default client to the context?
      plugins.add_plugin(Bolt::Plugin::Puppetdb.new(pdb_client))

      plugins.add_ruby_plugin('Bolt::Plugin::AwsInventory')
      plugins.add_ruby_plugin('Bolt::Plugin::InstallAgent')
      plugins.add_ruby_plugin('Bolt::Plugin::Task')
      plugins.add_ruby_plugin('Bolt::Plugin::Terraform')
      plugins.add_ruby_plugin('Bolt::Plugin::Pkcs7')
      plugins.add_ruby_plugin('Bolt::Plugin::Prompt')
      plugins.add_ruby_plugin('Bolt::Plugin::Vault')

      plugins
    end

    BUILTIN_PLUGINS = %w[task terraform pkcs7 prompt vault aws_inventory puppetdb azure_inventory].freeze

    attr_reader :pal, :plugin_context

    def initialize(config, pal, analytics)
      @config = config
      @analytics = analytics
      @plugin_context = PluginContext.new(config, pal)
      @plugins = {}
      @unknown = Set.new
    end

    def modules
      @modules ||= Bolt::Module.discover(@config.modulepath)
    end

    # Generally this is private. Puppetdb is special though
    def add_plugin(plugin)
      @plugins[plugin.name] = plugin
    end

    def add_ruby_plugin(cls_name)
      snake_name = Bolt::Util.class_name_to_file_name(cls_name)
      require snake_name
      cls = Kernel.const_get(cls_name)
      plugin_name = snake_name.split('/').last
      opts = {
        context: @plugin_context,
        config: config_for_plugin(plugin_name)
      }

      plugin = cls.new(**opts)
      add_plugin(plugin)
    end

    def add_module_plugin(plugin_name)
      opts = {
        context: @plugin_context,
        config: config_for_plugin(plugin_name)
      }

      plugin = Bolt::Plugin::Module.load(plugin_name, modules, opts)
      add_plugin(plugin)
    end

    def add_from_config
      @config.plugins.keys.each do |plugin_name|
        by_name(plugin_name)
      end
    end

    def config_for_plugin(plugin_name)
      @config.plugins[plugin_name] || {}
    end

    def get_hook(plugin_name, hook)
      plugin = by_name(plugin_name)
      raise PluginError::Unknown, plugin_name unless plugin
      raise PluginError::UnsupportedHook.new(plugin_name, hook) unless plugin.hooks.include?(hook)
      @analytics.report_bundled_content("Plugin #{hook}", plugin_name)

      plugin.method(hook)
    end

    # Calling by_name or get_hook will load any module based plugin automatically
    def by_name(plugin_name)
      return @plugins[plugin_name] if @plugins.include?(plugin_name)
      begin
        unless @unknown.include?(plugin_name)
          add_module_plugin(plugin_name)
        end
      rescue PluginError::Unknown
        @unknown << plugin_name
        nil
      end
    end
  end
end

# references PluginError
require 'bolt/plugin/module'
