/// The semantic kind of one unified-diff row.
public enum DiffRowKind: String, Sendable, Codable, Equatable {
    /// An unchanged context line.
    case context
    /// A new-side addition.
    case add
    /// An old-side deletion.
    case del
    /// Git's marker indicating that the preceding side has no trailing newline.
    case noNewline
}
