/// Safety policy for worktree and branch removal.
public struct WorktreeRemovalMode: Sendable {
    /// Whether `git worktree remove --force` may remove dirty files.
    public let forceWorktreeRemoval: Bool

    /// The branch cleanup policy.
    public let branchCleanup: WorktreeBranchCleanup

    /// Creates a removal policy.
    /// - Parameters:
    ///   - forceWorktreeRemoval: Whether dirty files may be discarded.
    ///   - branchCleanup: The branch cleanup performed after worktree removal.
    public init(
        forceWorktreeRemoval: Bool = false,
        branchCleanup: WorktreeBranchCleanup = .deleteIfMerged
    ) {
        self.forceWorktreeRemoval = forceWorktreeRemoval
        self.branchCleanup = branchCleanup
    }
}
