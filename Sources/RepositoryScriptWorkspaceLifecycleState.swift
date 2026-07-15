@MainActor
enum RepositoryScriptWorkspaceLifecycleState {
    case resolving(workspace: Workspace)
    case awaitingAuthorization(
        resolution: RepositoryScriptResolution,
        workspace: Workspace
    )
    case authorized(resolution: RepositoryScriptResolution)
    case closingAwaitingResolution
    case closingAwaitingAuthorization(resolution: RepositoryScriptResolution)
}
