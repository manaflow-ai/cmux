/// The completed outcome of a worktree removal.
public struct WorktreeRemovalResult: Equatable, Codable, Sendable {
    /// The identity that Git removed.
    public let worktree: WorktreeIdentity

    /// The branch cleanup outcome.
    public let branchCleanup: WorktreeBranchCleanupResult

    /// Whether stale administrative data was pruned during lazy recovery.
    public let prunedStaleAdministrativeData: Bool

    /// Creates a removal result.
    /// - Parameters:
    ///   - worktree: The removed worktree identity.
    ///   - branchCleanup: The branch cleanup outcome.
    ///   - prunedStaleAdministrativeData: Whether lazy stale-data recovery ran prune.
    public init(
        worktree: WorktreeIdentity,
        branchCleanup: WorktreeBranchCleanupResult,
        prunedStaleAdministrativeData: Bool
    ) {
        self.worktree = worktree
        self.branchCleanup = branchCleanup
        self.prunedStaleAdministrativeData = prunedStaleAdministrativeData
    }
}
