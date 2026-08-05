public import CmuxAgentReplica

/// Immutable view-state for one transcript list row.
public struct TranscriptRow: Hashable, Identifiable, Sendable {
    /// Stable identity used by diffable data sources.
    public let rowID: TranscriptRowID
    /// Renderable row payload.
    public let rowKind: TranscriptRowKind
    /// Whether this row is newer than the read pointer.
    public let isUnread: Bool
    /// Stable prompt-led turn identity, when the row belongs to a turn.
    public let turnID: TranscriptTurnID?
    /// Whether this row is the chronological end of its turn.
    public let endsTurn: Bool
    /// Full typed source entry retained for stable rendering and detail sheets.
    public let sourceEntry: EntrySnapshot?
    /// Deterministic display time fallback when the source has no timestamp.
    public let displayTick: Int?

    /// The `Identifiable` identity.
    public var id: TranscriptRowID { rowID }

    /// Creates a transcript row value.
    /// - Parameters:
    ///   - rowID: Stable identity used by diffable data sources.
    ///   - rowKind: Renderable row payload.
    ///   - isUnread: Whether this row is newer than the read pointer.
    ///   - turnID: Stable prompt-led turn identity.
    ///   - endsTurn: Whether this row ends its turn chronologically.
    public init(
        rowID: TranscriptRowID,
        rowKind: TranscriptRowKind,
        isUnread: Bool = false,
        turnID: TranscriptTurnID? = nil,
        endsTurn: Bool = false,
        sourceEntry: EntrySnapshot? = nil,
        displayTick: Int? = nil
    ) {
        self.rowID = rowID
        self.rowKind = rowKind
        self.isUnread = isUnread
        self.turnID = turnID
        self.endsTurn = endsTurn
        self.sourceEntry = sourceEntry
        self.displayTick = displayTick
    }
}
