/// Classifies one changed repository path.
public enum ChangesFileStatus: String, Sendable, Equatable {
    /// A tracked file was added.
    case added
    /// A tracked file's content or mode changed.
    case modified
    /// A tracked file was deleted.
    case deleted
    /// A tracked file moved from ``ChangesFile/oldPath``.
    case renamed
    /// A tracked file was copied from ``ChangesFile/oldPath``.
    case copied
    /// A non-ignored working-tree file is not tracked.
    case untracked
}
