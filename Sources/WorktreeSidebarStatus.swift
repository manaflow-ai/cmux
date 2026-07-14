/// Dirty-state projection for a visible worktree row.
enum WorktreeSidebarStatus: Equatable, Sendable {
    case unknown
    case loading
    case clean
    case dirty
    case unavailable
}
