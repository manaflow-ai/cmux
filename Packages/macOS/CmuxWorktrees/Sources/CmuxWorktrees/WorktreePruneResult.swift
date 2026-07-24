/// The output of an explicit or lazy `git worktree prune` operation.
public struct WorktreePruneResult: Equatable, Codable, Sendable {
    /// Git's verbose description of administrative records it removed.
    public let output: String

    /// Creates a prune result.
    /// - Parameter output: Trimmed standard output and standard error from Git.
    public init(output: String) {
        self.output = output
    }
}
