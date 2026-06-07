import Foundation

/// A parsed, structured view of one agent session transcript.
///
/// This is the shared model both macOS and iOS render. It is a pure value type
/// (`Sendable` + `Codable`) so it can be parsed off the main actor, cached, and
/// later streamed across a transport without any UI or IO dependency.
///
/// ```swift
/// let parser = ClaudeCodeTranscriptParser()
/// let conversation = parser.parse(lines: jsonlLines)
/// for message in conversation.messages where message.role == .assistant {
///     // render assistant turns
/// }
/// ```
public struct Conversation: Codable, Hashable, Sendable, Identifiable {
    /// A stable identifier for the conversation (the agent session id is used).
    public let id: String

    /// The agent that produced the transcript.
    public let agentKind: AgentKind

    /// The agent's own session identifier.
    public let sessionId: String

    /// The conversation's messages in transcript order.
    public let messages: [Message]

    /// A monotonically increasing version stamp.
    ///
    /// For a one-shot file read this is simply the message count; a future
    /// live-tailing source bumps it so consumers can detect and order updates.
    public let seq: UInt64

    /// Creates a conversation.
    ///
    /// - Parameters:
    ///   - id: A stable identifier for the conversation.
    ///   - agentKind: The agent that produced the transcript.
    ///   - sessionId: The agent's own session identifier.
    ///   - messages: The conversation's messages in transcript order.
    ///   - seq: A monotonically increasing version stamp.
    public init(
        id: String,
        agentKind: AgentKind,
        sessionId: String,
        messages: [Message],
        seq: UInt64
    ) {
        self.id = id
        self.agentKind = agentKind
        self.sessionId = sessionId
        self.messages = messages
        self.seq = seq
    }

    /// An empty conversation for the given session, used as a render placeholder
    /// before any transcript content is available.
    ///
    /// - Parameters:
    ///   - agentKind: The agent the placeholder represents.
    ///   - sessionId: The session the placeholder represents.
    /// - Returns: A conversation with no messages and `seq` 0.
    public static func empty(agentKind: AgentKind, sessionId: String) -> Conversation {
        Conversation(
            id: sessionId,
            agentKind: agentKind,
            sessionId: sessionId,
            messages: [],
            seq: 0
        )
    }
}
