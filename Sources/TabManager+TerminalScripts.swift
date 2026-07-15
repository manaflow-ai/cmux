extension TabManager {
    func configureTerminalScripts(runtime: RepositoryScriptRuntime) {
        repositorySetupPromptStore = runtime.promptStore
        repositoryScriptLifecycleCoordinator = runtime.lifecycleCoordinator
    }

    func savedTerminalCommand(named name: String?) -> String? {
        repositoryScriptLifecycleCoordinator?.savedCommand(named: name)
    }

    func runRepositoryScripts(for workspace: Workspace, directory: String) {
        repositoryScriptLifecycleCoordinator?.workspaceCreated(workspace, directory: directory)
    }

    func runRepositoryScriptsForSelectedWorkspaceIfNeeded() {
        guard let workspace = selectedWorkspace,
              let directory = workspace.currentDirectory else { return }
        runRepositoryScripts(for: workspace, directory: directory)
    }
}
