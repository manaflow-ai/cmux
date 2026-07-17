/// Represents one numbered row within a unified diff hunk.
public struct DiffRow: Sendable, Equatable {
    /// The row's semantic kind.
    public let kind: DiffRowKind
    /// The one-based old-side line number, when the row exists on that side.
    public let oldNo: Int?
    /// The one-based new-side line number, when the row exists on that side.
    public let newNo: Int?
    /// The row text without the unified-diff prefix marker.
    public let text: String

    /// Creates a diff row.
    /// - Parameters:
    ///   - kind: The row's semantic kind.
    ///   - oldNo: The old-side line number.
    ///   - newNo: The new-side line number.
    ///   - text: The line text without its diff marker.
    public init(kind: DiffRowKind, oldNo: Int?, newNo: Int?, text: String) {
        self.kind = kind
        self.oldNo = oldNo
        self.newNo = newNo
        self.text = text
    }
}
