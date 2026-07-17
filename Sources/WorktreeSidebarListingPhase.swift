/// Describes the current worktree listing lifecycle.
enum WorktreeSidebarListingPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed
}
