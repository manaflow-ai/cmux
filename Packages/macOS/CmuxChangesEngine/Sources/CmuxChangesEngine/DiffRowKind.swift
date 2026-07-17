/// Classifies one row in a unified diff hunk.
public enum DiffRowKind: String, Sendable, Equatable {
    /// An unchanged line present on both sides.
    case context
    /// A new-side addition.
    case add
    /// An old-side deletion.
    case del
    /// Git's marker that the preceding side lacks a trailing newline.
    case noNewline
}
