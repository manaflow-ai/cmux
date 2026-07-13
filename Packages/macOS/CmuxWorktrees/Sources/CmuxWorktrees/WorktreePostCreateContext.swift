/// Immutable context passed to a caller-supplied post-create hook.
public struct WorktreePostCreateContext: Sendable {
    /// The freshly listed worktree snapshot.
    public let worktree: WorktreeInfo

    /// The base ref supplied to `git worktree add` and recorded for lineage.
    public let baseRef: String

    /// Creates post-create context.
    /// - Parameters:
    ///   - worktree: The freshly created worktree.
    ///   - baseRef: The requested base ref.
    public init(worktree: WorktreeInfo, baseRef: String) {
        self.worktree = worktree
        self.baseRef = baseRef
    }
}
