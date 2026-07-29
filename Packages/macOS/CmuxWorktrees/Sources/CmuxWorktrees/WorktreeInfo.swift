/// A fresh Git-reported snapshot of one worktree.
public struct WorktreeInfo: Equatable, Codable, Sendable {
    /// The location-based worktree identity.
    public let identity: WorktreeIdentity

    /// The checked-out commit object ID, when Git reported one.
    public let headOID: String?

    /// The short local branch name, or `nil` for detached and bare entries.
    public let branch: String?

    /// Whether Git reports a detached checkout.
    public let isDetached: Bool

    /// Whether Git reports a bare repository entry.
    public let isBare: Bool

    /// Whether Git reports the worktree as locked.
    public let isLocked: Bool

    /// Git's lock reason, when one was recorded.
    public let lockReason: String?

    /// Whether Git reports stale administrative data that can be pruned.
    public let isPrunable: Bool

    /// Git's prunable reason, when one was reported.
    public let prunableReason: String?

    /// Whether this is the main worktree (the first porcelain entry).
    public let isMainWorktree: Bool

    /// Non-fatal diagnostics from the create call that returned this snapshot.
    /// Fresh listings always return an empty array.
    public let warnings: [WorktreeWarning]

    /// Creates a worktree snapshot.
    /// - Parameters:
    ///   - identity: The location-based worktree identity.
    ///   - headOID: The checked-out commit object ID, when available.
    ///   - branch: The short local branch name, when attached.
    ///   - isDetached: Whether Git reports a detached checkout.
    ///   - isBare: Whether Git reports a bare repository.
    ///   - isLocked: Whether Git reports the worktree as locked.
    ///   - lockReason: Git's optional lock reason.
    ///   - isPrunable: Whether Git reports prunable administrative data.
    ///   - prunableReason: Git's optional prunable reason.
    ///   - isMainWorktree: Whether this is the first porcelain entry.
    ///   - warnings: Non-fatal create diagnostics; listings pass an empty array.
    public init(
        identity: WorktreeIdentity,
        headOID: String?,
        branch: String?,
        isDetached: Bool,
        isBare: Bool,
        isLocked: Bool,
        lockReason: String?,
        isPrunable: Bool,
        prunableReason: String?,
        isMainWorktree: Bool,
        warnings: [WorktreeWarning] = []
    ) {
        self.identity = identity
        self.headOID = headOID
        self.branch = branch
        self.isDetached = isDetached
        self.isBare = isBare
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.prunableReason = prunableReason
        self.isMainWorktree = isMainWorktree
        self.warnings = warnings
    }

    func addingWarnings(_ warnings: [WorktreeWarning]) -> WorktreeInfo {
        WorktreeInfo(
            identity: identity,
            headOID: headOID,
            branch: branch,
            isDetached: isDetached,
            isBare: isBare,
            isLocked: isLocked,
            lockReason: lockReason,
            isPrunable: isPrunable,
            prunableReason: prunableReason,
            isMainWorktree: isMainWorktree,
            warnings: warnings
        )
    }
}
