/// One parsed row inside a unified-diff hunk.
public struct DiffRow: Sendable, Codable, Equatable {
    /// The semantic row kind.
    public let kind: DiffRowKind
    /// The one-based old-side line number when present.
    public let oldNo: Int?
    /// The one-based new-side line number when present.
    public let newNo: Int?
    /// Row text without the unified-diff prefix marker.
    public let text: String

    /// Creates a parsed diff row.
    /// - Parameters:
    ///   - kind: The semantic row kind.
    ///   - oldNo: The old-side line number when present.
    ///   - newNo: The new-side line number when present.
    ///   - text: Row text without its unified-diff prefix.
    public init(kind: DiffRowKind, oldNo: Int?, newNo: Int?, text: String) {
        self.kind = kind
        self.oldNo = oldNo
        self.newNo = newNo
        self.text = text
    }
}
