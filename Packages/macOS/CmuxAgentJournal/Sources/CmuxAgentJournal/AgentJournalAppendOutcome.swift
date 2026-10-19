/// Durable acknowledgement returned by ``AgentJournalStore/append(_:committedAt:)``.
///
/// Mirrors the cmux-tui journal's commit receipt: a replayed append (same
/// `event_id` seen before) returns the original sequence instead of writing a
/// second record, so producer retries are idempotent.
public struct AgentJournalAppendOutcome: Sendable, Equatable {
    /// The committed (or previously committed) journal sequence.
    public let sequence: Int64
    /// Commit timestamp of the (original) record, ms since the Unix epoch.
    public let committedAtMs: Int64
    /// Whether this append deduplicated against an existing record.
    public let replayed: Bool

    /// Creates an outcome.
    ///
    /// - Parameters:
    ///   - sequence: The committed journal sequence.
    ///   - committedAtMs: Commit timestamp of the (original) record.
    ///   - replayed: Whether the append deduplicated against an existing record.
    public init(sequence: Int64, committedAtMs: Int64, replayed: Bool) {
        self.sequence = sequence
        self.committedAtMs = committedAtMs
        self.replayed = replayed
    }
}
