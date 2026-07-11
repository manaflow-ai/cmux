/// Stable compact presentation of one entry inside a turn's activity.
public struct TranscriptActivityItem: Hashable, Identifiable, Sendable {
    /// Underlying entry identity.
    public let id: TranscriptRowID
    /// Semantic activity kind.
    public let kind: TranscriptActivityKind
    /// One-line activity detail.
    public let summary: String
    /// Whether this activity is still running.
    public let isRunning: Bool

    /// Creates a compact activity item.
    public init(id: TranscriptRowID, kind: TranscriptActivityKind, summary: String, isRunning: Bool) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.isRunning = isRunning
    }
}
