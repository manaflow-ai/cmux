/// Errors thrown by ``AgentJournalStore``.
public enum AgentJournalStoreError: Error, Sendable, Equatable {
    /// `sqlite3_open_v2` failed with the given result code.
    case openFailed(Int32)
    /// Statement preparation failed with the given result code and message.
    case prepareFailed(Int32, String)
    /// Statement execution failed with the given result code and message.
    case stepFailed(Int32, String)
    /// The draft failed admission validation.
    case invalidDraft(String)
    /// The same event id was appended again with different content.
    case idempotencyConflict(String)
    /// The store has been closed.
    case closed
}
