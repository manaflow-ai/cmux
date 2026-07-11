/// Immutable view-state for one transcript list row.
public struct TranscriptRow: Hashable, Identifiable, Sendable {
    /// Stable identity used by diffable data sources.
    public let rowID: TranscriptRowID
    /// Renderable row payload.
    public let rowKind: TranscriptRowKind
    /// Whether this row is newer than the read pointer.
    public let isUnread: Bool

    /// The `Identifiable` identity.
    public var id: TranscriptRowID { rowID }

    /// Creates a transcript row value.
    /// - Parameters:
    ///   - rowID: Stable identity used by diffable data sources.
    ///   - rowKind: Renderable row payload.
    ///   - isUnread: Whether this row is newer than the read pointer.
    public init(rowID: TranscriptRowID, rowKind: TranscriptRowKind, isUnread: Bool = false) {
        self.rowID = rowID
        self.rowKind = rowKind
        self.isUnread = isUnread
    }
}
