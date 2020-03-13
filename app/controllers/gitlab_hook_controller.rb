require 'json'

class GitlabHookController < SysController

  GIT_BIN = Redmine::Configuration[:scm_git_command] || 'git'


  def index
    raise ActionController::RoutingError.new('Not Found') unless request.post?
    target_branch = get_target_branch
    unless branches().include?(target_branch)
      raise ActionController::RoutingError.new('Not Found')
    end

    repository = find_repository(target_branch)
    raise ActionController::RoutingError.new('Not Found') unless repository

    # Fetch the changes from GitLab
    if Setting.plugin_redmine_gitlab_hook['fetch_updates'] == 'yes'
      git_success = update_repository(repository, target_branch)
    else
      git_success = truee
    end

    if git_success
      # Fetch the new changesets into Redmine
      repository.fetch_changesets
      render(:plain => 'OK', :status => :ok)
    else
      render(:plain => "Git command failed on repository: #{repository.identifier}!", :status => :not_acceptable)
    end
  end


  private


  def system(command)
    Kernel.system(command)
  end


  # Executes shell command. Returns true if the shell command exits with a success status code
  def exec(command)
    logger.debug { "GitLabHook: Executing command: '#{command}'" }

    # Get a path to a temp file
    logfile = Tempfile.new('gitlab_hook_exec')
    logfile.close

    success = system("#{command} > #{logfile.path} 2>&1")
    output_from_command = File.readlines(logfile.path)
    if success
      logger.debug { "GitLabHook: Command output: #{output_from_command.inspect}"}
    else
      logger.error { "GitLabHook: Command '#{command}' didn't exit properly. Full output: #{output_from_command.inspect}"}
    end

    return success
  ensure
    logfile.unlink
  end


  def git_command(prefix, command, repository)
    "#{prefix} #{GIT_BIN} --git-dir='#{repository.url}' #{command}"
  end


  def clone_repository(prefix, remote_url, local_url, target_branch)
    "#{prefix} #{GIT_BIN} clone --bare -b #{target_branch} --single-branch #{remote_url} #{local_url}"
  end


  # Fetches updates from the remote repository
  def update_repository(repository, target_branch)
    Setting.plugin_redmine_gitlab_hook['prune'] == 'yes' ? prune = ' -p' : prune = ''
    prefix = Setting.plugin_redmine_gitlab_hook['git_command_prefix'].to_s

    branches = Setting.plugin_redmine_gitlab_hook['branches']
    branches.include?(target_branch) or return
    if exec(git_command(
        prefix, "fetch#{prune} -f origin #{target_branch}:#{target_branch}",
        repository))
      exec(git_command(prefix, "git reset --soft FETCH_HEAD", repository))
    end
  end


  def get_repository_name
    return params[:repository_name] && params[:repository_name].downcase
  end


  def get_repository_namespace
    return params[:repository_namespace] && params[:repository_namespace].downcase
  end


  def branches
    Setting.plugin_redmine_gitlab_hook['branches'].split(/[,\s]/)
  end

  def get_target_branch
    evt = JSON.parse(request.body.string)
    unless evt['object_kind'] == 'merge_request'
      raise ActionController::RoutingError.new(
        "object_kind #{evt['object_kind']} would not be handled.")
    end

    return evt['object_attributes']['target_branch']
  end


  # Gets the repository identifier from the querystring parameters and if that's not supplied, assume
  # the GitLab project identifier is the same as the repository identifier.
  def get_repository_identifier
    repo_namespace = get_repository_namespace
    repo_name = get_repository_name || get_project_identifier
    identifier = repo_namespace.present? ? "#{repo_namespace}_#{repo_name}" : repo_name
    return identifier
  end

  # Gets the project identifier from the querystring parameters and if that's not supplied, assume
  # the GitLab repository identifier is the same as the project identifier.
  def get_project_identifier
    identifier = params[:project_id] || params[:repository_name]
    raise ActiveRecord::RecordNotFound, 'Project identifier not specified' if identifier.nil?
    return identifier
  end


  # Finds the Redmine project in the database based on the given project identifier
  def find_project
    identifier = get_project_identifier
    project = Project.find_by_identifier(identifier.downcase)
    raise ActiveRecord::RecordNotFound, "No project found with identifier '#{identifier}'" if project.nil?
    return project
  end


  # Returns the Redmine Repository object we are trying to update
  def find_repository(target_branch)
    project = find_project
    repository_id = get_repository_identifier
    repository = project.repositories.find_by_identifier_param(repository_id)

    if repository.nil?
      if Setting.plugin_redmine_gitlab_hook['auto_create'] == 'yes'
        repository = create_repository(project, target_branch)
      else
        raise TypeError, "Project '#{project.to_s}' ('#{project.identifier}') has no repository or repository not found with identifier '#{repository_id}'"
      end
    else
      unless repository.is_a?(Repository::Git)
        raise TypeError, "'#{repository_id}' is not a Git repository"
      end
    end

    return repository
  end


  def create_repository(project, target_branch)
    logger.debug('Trying to create repository...')
    raise TypeError, 'Local repository path is not set' unless Setting.plugin_redmine_gitlab_hook['local_repositories_path'].to_s.present?

    identifier = get_repository_identifier
    remote_url = params[:repository_git_url]
    prefix = Setting.plugin_redmine_gitlab_hook['git_command_prefix'].to_s

    raise TypeError, 'Remote repository URL is null' unless remote_url.present?

    local_root_path = Setting.plugin_redmine_gitlab_hook['local_repositories_path']
    repo_namespace = get_repository_namespace
    repo_name = get_repository_name
    local_url = File.join(local_root_path, repo_namespace, repo_name)
    git_file = File.join(local_url, 'HEAD')

    unless File.exists?(git_file)
      FileUtils.mkdir_p(local_url)
      command = clone_repository(prefix, remote_url, local_url, target_branch)
      unless exec(command)
        raise RuntimeError, "Can't clone URL #{remote_url}"
      end
    end
    repository = Repository::Git.new
    repository.identifier = identifier
    repository.url = local_url
    repository.is_default = true
    repository.project = project
    repository.save
    return repository
  end

end
