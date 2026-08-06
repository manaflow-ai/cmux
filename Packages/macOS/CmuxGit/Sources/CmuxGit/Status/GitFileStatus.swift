/// A working-tree status reported by `git status --porcelain`.
public enum GitFileStatus: Equatable, Sendable {
    /// File contents or metadata differ from the index.
    case modified
    /// The index contains a newly added path.
    case added
    /// A tracked path was removed.
    case deleted
    /// A tracked path moved to a new name.
    case renamed
    /// Git does not track the path.
    case untracked
}
