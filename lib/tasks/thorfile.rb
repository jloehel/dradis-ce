class DradisTasks < Thor
  namespace       "dradis"

  desc      "backup", "creates a backup of your current repository"
  long_desc "Creates a backup of the current repository, including all nodes, notes and " +
            "attachments as a zipped archive. The backup can be imported into another " +
            "dradis instance using the 'Project Package Upload' option."
  method_option   :path, :type => :string, :desc => "the backup file destination directory"
  def backup
    require 'config/environment'

    invoke "dradis:plugins:projects:export:package"
  end

  desc      "reset", "resets your local dradis repository"
  long_desc "Resets your dradis repository, removing all nodes, notes and attachments and log files " +
            "so it is ready to start a new project.\n\nA backup of the current repository "+
            "will be taken before anything is removed."
  method_option   :file, :type => :string, :desc => "the backup file to create, or directory to create it in"
  method_option   :no_backup, :type => :boolean, :desc => "do not create a backup of the current repository"
  def reset
    invoke "dradis:setup:configure", [], []
    invoke "dradis:setup:migrate", [], []

    invoke "dradis:backup", [], options            unless options.no_backup

    invoke "dradis:reset:attachments", [], []
    invoke "dradis:reset:database", [], []
    invoke "dradis:setup:seed", [], []
    invoke "dradis:reset:logs", [], []
  end

  desc "server", "start dradis server"
  method_option   :p, :type => :string, :desc => "specify the port to listen to (default 3004)"
  method_option   :b, :type => :string, :desc => "bind to a specific IP address (default 0.0.0.0)"
  method_option   :d, :type => :boolean, :desc => "run in the background"
  method_option   :P, :type => :string, :desc => "specify the location of the PID file (default tmp/pids)"
  def server
    require 'rubygems'

    ARGV.shift        # remove dradis:server from the command-line arguments
    ARGV.unshift 's'  # add 's' to the beginning of the command-line arguments,
                      # because we want a server

    gem 'rails', ">= 0"
    # now that we've massaged the arguments a little, we let Rails take over and
    # do its magic (this is essentially invoking 'rails s' with all the options
    # passed into Thor
    load Gem.bin_path('rails', 'rails', ">= 0")
  end

  desc "version", "displays the version of the dradis server"
  def version
    require 'lib/core/version'
    puts Core::VERSION::string
    puts Core::Pro::VERSION::string
  end


  class Import < Thor; end
  class Export < Thor; end
  class Upload < Thor; end


  class Setup < Thor
    include Thor::Actions
    include ::Rails.application.config.dradis.thor_helper_module

    namespace     "dradis:setup"

    def self.source_root
      File.join(File.dirname(__FILE__), 'templates')
    end

    desc "configure", "Creates the Dradis configuration files from their templates (see config/*.yml.template)"
    def configure
      # init the config files
      init_all = false
      Dir['config/*.template'].each do |template|
        config = File.join( 'config', File.basename(template, '.template') )
        if !(File.exists?( config ))
          if (init_all)
            puts "Initilizing #{config}..."
            FileUtils.cp(template, config)
          else
            puts "The config file [#{template}] was found not to be ready to use."
            puts "Do you want to initialize it? [y]es | [N]o | initialize [a]ll"
            response = STDIN.gets.chomp.downcase
            response = 'Y' if ( response.empty? || !['y', 'n', 'a'].include?(response) )

            if response == 'n'
              next
            else
              puts "Initilizing #{config}..."
              FileUtils.cp(template, config)
              if (response == 'a')
                init_all = true
              end
            end
          end
        end
      end
    end

    desc "migrate", "ensures the database schema is up-to-date"
    def migrate
      require 'config/environment'

      print "** Checking database migrations...                                    "
      ActiveRecord::Migrator.migrate("db/migrate/", nil)
      puts "[  DONE  ]"
    end

    desc "seed", "adds initial values to the database (i.e., categories and configurations)"
    def seed
      require 'config/environment'

      print "** Seeding database...                                                "
      require 'db/seeds'
      puts "[  DONE  ]"
    end

    desc "kit SETUP_PACKAGE", "import files and projects from a specified kit file"
    method_option :file, :type => :string, :desc => "full path to a zip file"
    def kit(file)
      puts "** Importing package..."
      KitImportJob.perform_now(file: file, logger: default_logger)
      puts "[  DONE  ]"
    end

    desc "welcome", "adds initial content to the repo for demonstration purposes"
    def welcome
      # zip lib/tasks/welcome_kit
      directory_to_zip = Rails.root.join('lib', 'tasks', 'welcome_kit')
      temporary_zip = Tempfile.new

      entries = Dir["#{directory_to_zip}/**/**"]
      Zip::File.open(temporary_zip.path, Zip::File::CREATE) do |zipfile|
        entries.each do |file|
          next if File.directory?(file)
          in_zip_file = file.sub(Rails.root.join('lib', 'tasks', 'welcome_kit').to_s, 'kit')
          zipfile.add(in_zip_file, file)
        end
      end

      invoke 'dradis:setup:kit', [], [file: temporary_zip.path]
      #FileUtils.cp temporary_zip.path, Rails.root.join('tmp')
    end

    desc "welcome_old", "adds initial content to the repo for demonstration purposes"
    def welcome_old
      # --------------------------------------------------------- Note template
      if NoteTemplate.pwd.exist?
        say 'Note templates folder already exists. Skipping.'
      else
        template 'note.txt', NoteTemplate.pwd.join('basic_fields.txt')
      end

      # ----------------------------------------------------------- Methodology
      if Methodology.pwd.exist?
        say 'Methodology templates folder already exists. Skipping.'
      else
        template 'methodology.xml', Methodology.pwd.join('owasp2017.xml')
      end

      # ---------------------------------------------------------- Project data
      detect_and_set_project_scope

      task_options.merge!({
        plugin: Dradis::Plugins::Projects::Upload::Template,
        default_user_id: 1
      })

      importer = Dradis::Plugins::Projects::Upload::Template::Importer.new(task_options)
      importer.import(file: File.expand_path('../templates/project.xml', __FILE__))

      # dradis:reset:database truncates the tables and resets the :id column so
      # we know the right node ID we're going to get based on the project.xml
      # structure.
      Dir.mkdir(Attachment.pwd.join('5'))
      template 'command-01.png', Attachment.pwd.join('5/command-01.png')
    end
  end

  class Logs < Thor
    namespace     "dradis:logs"

    desc "clean DAYS", "delete all logs older than DAYS days (default 7)"
    def clean(days=7)
      puts "Clearing old Logs..."
      logs  = Log.where("created_at < (?)", days.to_i.days.ago)
      count = logs.count
      logs.destroy_all
      puts "Deleted #{count} Log#{"s" if count != 1}"
    end
  end

  class Reset < Thor
    namespace     "dradis:reset"

    desc "attachments", "removes all attachments"
    def attachments
      print "** Deleting all attachments...                                        "
      FileUtils.rm_rf(Dir.glob( Attachment::AttachmentPwd.join('*')) )
      puts(Dir.glob( Attachment::AttachmentPwd.join('*')).empty? ? "[  DONE  ]" : "[ FAILED ]")
    end

    desc "database", "removes all data from a dradis repository, except configurations"
    def database
      return if defined?(Dradis::Pro)

      require 'config/environment'
      print "** Cleaning database...                                               "

      Rails.application.eager_load!
      (ApplicationRecord.descendants - [Configuration]).each do |model|
        ActiveRecord::Base.connection.execute("DELETE FROM #{model.table_name}")
        ActiveRecord::Base.connection.execute("DELETE FROM sqlite_sequence WHERE name='#{model.table_name}'")
      end

      puts "[  DONE  ]"
    end

    desc "logs", "removes all log files"
    def logs
      print "** Deleting all log files...                                          "
      FileUtils.rm_rf(Dir.glob('log/*.log'))
      puts(Dir.glob('log/*.log').empty? ? "[  DONE  ]" : "[ FAILED ]")
    end

    desc "password", "Set a new shared password to access the web interface"
    def password()
      require 'config/environment'

      say "Changing password for Dradis server."
      password = ask "Enter new Dradis password:"
      confirmation = ask "Retype new Dradis password:"

      if !password.blank? && password == confirmation
        Configuration.find_or_create_by(name: 'admin:password').update_attribute(:value, ::BCrypt::Password.create(password))
        say("Password Changed.", Thor::Shell::Color::GREEN)
      else
        say("Passwords do not match. Password Unchanged.", Thor::Shell::Color::RED)
      end
    end
  end
end
