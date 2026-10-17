public import Foundation

/// The transport-independent client contract used by iOS and macOS callers.
public protocol ConversationClient: Sendable {
    /// Lists sessions visible to the authenticated workspace.
    func listSessions() async throws -> [ConversationSession]
    /// Creates and starts a managed session.
    func createSession(_ request: ConversationCreateRequest) async throws -> ConversationSession
    /// Reads the latest complete projection.
    func snapshot(sessionID: ConversationID) async throws -> ConversationSnapshot
    /// Replays events strictly after a cursor.
    func replay(sessionID: ConversationID, after: ConversationCursor) async throws -> [ConversationEvent]
    /// Registers an event stream before snapshot/replay to avoid a reconnect race.
    func events(sessionID: ConversationID, after: ConversationCursor) async -> AsyncThrowingStream<ConversationEvent, any Error>
    /// Executes one durable command envelope.
    func execute(_ command: ConversationCommandEnvelope) async throws -> ConversationReceipt
    /// Reads a previously persisted command receipt without dispatching it.
    func receipt(_ query: ConversationReceiptQuery) async throws -> ConversationReceipt?
    /// Reads a durable command receipt by session and command identity.
    func receipt(sessionID: ConversationID, commandID: ConversationCommandID) async throws -> ConversationReceipt?
}
