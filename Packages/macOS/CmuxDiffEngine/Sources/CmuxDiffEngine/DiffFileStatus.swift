/// The working-tree status of one changed path.
public enum DiffFileStatus: String, Sendable, Codable, Equatable {
    /// A tracked file was added.
    case added
    /// A tracked file was modified or changed type.
    case modified
    /// A tracked file was deleted.
    case deleted
    /// A tracked file moved from ``DiffFileSummary/oldPath``.
    case renamed
    /// A tracked file was copied from ``DiffFileSummary/oldPath``.
    case copied
    /// A regular file is not tracked by Git.
    case untracked
}
