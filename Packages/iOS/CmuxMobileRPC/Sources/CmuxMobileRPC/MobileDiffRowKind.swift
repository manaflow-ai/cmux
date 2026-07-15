/// The semantic wire kind of a unified-diff row.
public enum MobileDiffRowKind: String, Codable, Sendable, Equatable {
    /// An unchanged context line.
    case context
    /// A new-side addition.
    case add
    /// An old-side deletion.
    case del
    /// Git's no-trailing-newline marker.
    case noNewline
}
