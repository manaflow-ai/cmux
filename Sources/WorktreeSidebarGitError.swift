/// Typed failures from the app-side Git worktree service.
enum WorktreeSidebarGitError: Error, Sendable {
    enum Operation: Sendable {
        case list
        case status
        case inspect
        case create
        case remove
        case prune
        case initializeSubmodules
    }

    case commandFailed(Operation, details: String)
    case invalidBranchName(String)
    case mainWorktree
    case locked(reason: String?)
    case containsRegisteredWorktrees
    case worktreeNotFound
    case worktreeChanged
    case forceRequired
    case submoduleInitializationFailed(WorktreeSidebarCreationResult, details: String)
}
