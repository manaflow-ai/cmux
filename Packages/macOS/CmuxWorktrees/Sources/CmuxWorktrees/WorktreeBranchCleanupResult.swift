/// The outcome of branch cleanup after a worktree was removed.
public enum WorktreeBranchCleanupResult: Equatable, Codable, Sendable {
    /// No local branch was associated with the worktree.
    case notApplicable
    /// The branch was deleted.
    case deleted(branch: String)
    /// The branch was deliberately or safely preserved.
    case preserved(branch: String, reason: WorktreeBranchPreservationReason)
}
