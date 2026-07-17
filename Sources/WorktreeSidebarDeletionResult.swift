/// The authoritative outcome after Git removes or prunes a worktree registration.
struct WorktreeSidebarDeletionResult: Equatable, Sendable {
    typealias Removal = WorktreeSidebarDeletionRemoval
    typealias Branch = WorktreeSidebarDeletionBranchResult

    let removal: Removal
    let branch: Branch
}
