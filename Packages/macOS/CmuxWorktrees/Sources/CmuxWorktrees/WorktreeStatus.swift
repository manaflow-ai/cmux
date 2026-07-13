/// A cheap point-in-time status snapshot for one worktree.
public struct WorktreeStatus: Equatable, Codable, Sendable {
    /// The worktree identity inspected.
    public let worktree: WorktreeIdentity

    /// The current branch, or `nil` for a detached checkout.
    public let branch: String?

    /// The number of tracked, untracked, and conflicted path records.
    public let dirtyFileCount: Int

    /// The configured upstream ref, or `nil` when none exists.
    public let upstream: String?

    /// Commits reachable from HEAD but not the upstream.
    public let aheadCount: Int

    /// Commits reachable from the upstream but not HEAD.
    public let behindCount: Int

    /// Merge or rebase work currently in progress.
    public let operation: WorktreeOperation?

    /// Creates a worktree status snapshot.
    /// - Parameters:
    ///   - worktree: The inspected worktree identity.
    ///   - branch: The current short branch name, when attached.
    ///   - dirtyFileCount: The count of changed path records.
    ///   - upstream: The configured upstream ref, when present.
    ///   - aheadCount: Commits reachable only from HEAD.
    ///   - behindCount: Commits reachable only from the upstream.
    ///   - operation: A merge or rebase currently in progress.
    public init(
        worktree: WorktreeIdentity,
        branch: String?,
        dirtyFileCount: Int,
        upstream: String?,
        aheadCount: Int,
        behindCount: Int,
        operation: WorktreeOperation?
    ) {
        self.worktree = worktree
        self.branch = branch
        self.dirtyFileCount = dirtyFileCount
        self.upstream = upstream
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.operation = operation
    }
}
