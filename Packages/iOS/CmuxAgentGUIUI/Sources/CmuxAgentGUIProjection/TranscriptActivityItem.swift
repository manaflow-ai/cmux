/// Stable compact presentation of one entry inside a turn's activity.
public import CmuxAgentReplica

public struct TranscriptActivityItem: Hashable, Identifiable, Sendable {
    /// Underlying entry identity.
    public let id: TranscriptRowID
    /// Semantic activity kind.
    public let kind: TranscriptActivityKind
    /// One-line activity detail.
    public let summary: String
    /// Whether this activity is still running.
    public let isRunning: Bool
    /// Full typed source entry retained for out-of-flow detail presentation.
    public let sourceEntry: EntrySnapshot?

    /// Creates a compact activity item.
    public init(
        id: TranscriptRowID,
        kind: TranscriptActivityKind,
        summary: String,
        isRunning: Bool,
        sourceEntry: EntrySnapshot? = nil
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.isRunning = isRunning
        self.sourceEntry = sourceEntry
    }
}
