/// Represents one numbered row within a unified diff hunk.
public struct MobileChangesDiffRow: Codable, Sendable, Equatable {
    /// The row's semantic kind.
    public let kind: MobileChangesRowKind
    /// The one-based old-side line number, when the row exists on that side.
    public let oldNo: Int?
    /// The one-based new-side line number, when the row exists on that side.
    public let newNo: Int?
    /// The row text without the leading unified-diff marker.
    public let text: String

    /// Creates a unified-diff row.
    /// - Parameters:
    ///   - kind: The row's semantic kind.
    ///   - oldNo: The one-based old-side line number, when present.
    ///   - newNo: The one-based new-side line number, when present.
    ///   - text: The row text without the diff marker.
    public init(kind: MobileChangesRowKind, oldNo: Int?, newNo: Int?, text: String) {
        self.kind = kind
        self.oldNo = oldNo
        self.newNo = newNo
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case oldNo = "old_no"
        case newNo = "new_no"
        case text
    }
}
