public import Foundation

/// Identifies a session and optional replay cursor in RPC queries.
public struct ConversationSessionQuery: Codable, Hashable, Sendable {
    /// Session identity.
    public let sessionID: ConversationID
    /// Return events after this cursor when supplied.
    public let after: ConversationCursor?
    /// Creates a session query.
    public init(sessionID: ConversationID, after: ConversationCursor? = nil) { self.sessionID = sessionID; self.after = after }
}

/// Identifies a durable command receipt.
public struct ConversationReceiptQuery: Codable, Hashable, Sendable {
    /// Session identity.
    public let sessionID: ConversationID
    /// Command identity.
    public let commandID: ConversationCommandID
    /// Creates a receipt query.
    public init(sessionID: ConversationID, commandID: ConversationCommandID) { self.sessionID = sessionID; self.commandID = commandID }
}
