/// A chat backend: lists conversations, opens them, and runs commands.
///
/// Implemented per backend (acpmux is the first); everything above it uses
/// only this protocol and the types in this package.
public protocol ConversationBackend: Sendable {
    /// Reachability, starting with the current value.
    func connectionStates() -> AsyncStream<BackendConnectionState>
    /// The live conversation list, starting with the current list.
    func conversationList() -> AsyncStream<[ConversationSummary]>
    /// Opens a conversation's feed.
    /// - Parameters:
    ///   - id: The conversation.
    ///   - pageSize: How many of the newest events to load first.
    /// - Returns: The open feed.
    /// - Throws: When the conversation does not exist or the backend is unreachable.
    func open(_ id: ConversationID, pageSize: Int) async throws -> any ConversationFeed
    /// Creates a conversation whose first message is `message`.
    ///
    /// Idempotent per `message.clientMessageID`: a resend returns the
    /// conversation the first call created.
    /// - Parameters:
    ///   - settings: The new conversation's settings.
    ///   - message: Its first message (sent separately with ``perform(_:on:)``).
    /// - Returns: The new conversation's identifier.
    /// - Throws: When the backend refuses or is unreachable.
    func create(settings: ConversationSettings, firstMessage message: OutgoingMessage) async throws -> ConversationID
    /// Runs a command. Returns once the backend has it; results arrive as events.
    /// - Parameters:
    ///   - command: What to do.
    ///   - id: The conversation.
    /// - Throws: When the backend refuses or is unreachable.
    func perform(_ command: ConversationCommand, on id: ConversationID) async throws
    /// Uploads a file for a message, resuming where an earlier attempt stopped.
    /// - Parameters:
    ///   - file: The file.
    ///   - id: The conversation the message belongs to.
    /// - Returns: Bytes the backend holds, as they arrive; finishes when verified.
    func upload(_ file: UploadFile, to id: ConversationID) -> AsyncThrowingStream<UInt64, any Error>
}
