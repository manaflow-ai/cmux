/// The seam between chat surfaces and whatever produces conversation data.
///
/// ``ChatConversationStore`` depends only on this protocol. On iOS the
/// implementation adapts the mobile RPC client; a future macOS surface can
/// implement it in-process against the host's own transcript service. Test
/// and preview surfaces use ``FixtureChatEventSource``.
public protocol ChatEventSource: Sendable {
    /// Fetches a page of transcript history for a session.
    ///
    /// - Parameters:
    ///   - sessionID: The session to read.
    ///   - beforeSeq: Return only messages with seq strictly below this
    ///     cursor; `nil` returns the newest page.
    ///   - limit: Maximum number of messages to return.
    /// - Returns: The page, ordered by ascending seq.
    func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage

    /// Opens the live event stream for a session.
    ///
    /// The stream finishes when the underlying connection closes; callers
    /// re-subscribe after reconnect. Implementations honor stream
    /// termination (consumer cancellation) by tearing down their
    /// subscription.
    ///
    /// - Parameter sessionID: The session to observe.
    /// - Returns: Live updates, in delivery order.
    func events(sessionID: String) async -> AsyncStream<ChatSessionEvent>

    /// Sends a user prompt (and optional attachments) to the session.
    ///
    /// Attachments are delivered to the host first so the prompt can
    /// reference them; the text is then injected into the agent's terminal.
    ///
    /// - Parameters:
    ///   - text: The prompt text.
    ///   - attachments: Images to deliver ahead of the prompt.
    ///   - sessionID: The destination session.
    func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws

    /// Interrupts the session's agent.
    ///
    /// - Parameters:
    ///   - sessionID: The session to interrupt.
    ///   - hard: `false` sends the agent's polite interrupt (Esc);
    ///     `true` sends a hard interrupt (ctrl-C).
    func interrupt(sessionID: String, hard: Bool) async throws

    /// Answers a pending in-terminal choice (question option or permission
    /// button) by its display index.
    ///
    /// Implementations translate the index into whatever the agent's
    /// terminal UI expects (number key, arrow + return).
    ///
    /// - Parameters:
    ///   - optionIndex: Zero-based index of the chosen option.
    ///   - sessionID: The session being answered.
    func answer(optionIndex: Int, sessionID: String) async throws
}
