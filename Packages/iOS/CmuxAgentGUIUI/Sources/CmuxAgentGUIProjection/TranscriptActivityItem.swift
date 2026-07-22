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
    /// The process exit code, when this item represents a completed tool run.
    public let exitCode: Int?
    /// Whether the activity completed with a user-visible failure.
    public let isFailed: Bool

    /// Creates a compact activity item.
    /// - Parameters:
    ///   - id: Stable identity of the source entry.
    ///   - kind: Semantic activity kind.
    ///   - summary: Safe one-line activity detail.
    ///   - isRunning: Whether the activity is still running.
    ///   - exitCode: Tool process exit code, when reported.
    ///   - isFailed: Whether the activity failed.
    public init(
        id: TranscriptRowID,
        kind: TranscriptActivityKind,
        summary: String,
        isRunning: Bool,
        exitCode: Int? = nil,
        isFailed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.isRunning = isRunning
        self.exitCode = exitCode
        self.isFailed = isFailed
    }
}
