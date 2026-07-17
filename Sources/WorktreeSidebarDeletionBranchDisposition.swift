/// Describes how worktree removal should handle its local branch.
enum WorktreeSidebarDeletionBranchDisposition: Equatable, Sendable {
    case deleteMerged(String)
    case keepUnmerged(String)
    case noLocalBranch
}
