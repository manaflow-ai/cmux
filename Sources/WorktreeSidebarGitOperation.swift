/// Identifies the Git operation associated with a worktree service failure.
enum WorktreeSidebarGitOperation: Sendable {
    case list
    case status
    case inspect
    case create
    case remove
    case prune
    case initializeSubmodules
}
