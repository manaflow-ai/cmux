/// The git working-tree status of a single path, projected for the file explorer.
///
/// Derived from a `git status --porcelain` line's index and work-tree status
/// characters by ``GitStatusService``. Directories inherit a coarse status
/// (``modified`` or ``untracked``) from their descendants.
public enum GitFileStatus: Sendable, Equatable {
    /// The path has staged or unstaged content changes (`M`).
    case modified
    /// The path was added (`A`).
    case added
    /// The path was deleted (`D`).
    case deleted
    /// The path was renamed (`R`).
    case renamed
    /// The path is not tracked by git (`??`).
    case untracked
}
