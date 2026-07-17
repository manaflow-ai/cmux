/// Records the authoritative local-branch outcome after worktree removal.
enum WorktreeSidebarDeletionBranchResult: Equatable, Sendable {
    case deleted(String)
    case preserved(String, reason: String)
    case notApplicable
}
