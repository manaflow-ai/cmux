/// A Git operation currently in progress inside a worktree.
public enum WorktreeOperation: String, Equatable, Codable, Sendable {
    /// A merge has an active `MERGE_HEAD`.
    case merge
    /// A rebase has an active `rebase-merge` or `rebase-apply` directory.
    case rebase
}
