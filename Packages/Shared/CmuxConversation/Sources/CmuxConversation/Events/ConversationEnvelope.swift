/// A ``ConversationEvent`` with its place in the conversation's history.
public struct ConversationEnvelope: Hashable, Sendable {
    /// Where it sits in the history; drives ordering and deduplication.
    public let cursor: ConversationCursor
    /// When the backend recorded it, in milliseconds since 1970, if known.
    public let timestamp: UInt64?
    /// What happened.
    public let event: ConversationEvent

    /// Creates an envelope.
    /// - Parameters:
    ///   - cursor: Position in the history.
    ///   - timestamp: Recording time in milliseconds.
    ///   - event: What happened.
    public init(cursor: ConversationCursor, timestamp: UInt64?, event: ConversationEvent) {
        self.cursor = cursor
        self.timestamp = timestamp
        self.event = event
    }
}
