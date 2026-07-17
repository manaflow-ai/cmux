/// Coalesces worktree listing refreshes while one request is active.
enum WorktreeSidebarModelRefreshState {
    case idle
    case running(needsRerun: Bool)
}
