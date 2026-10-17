/// One page of transcript history, served oldest-to-newest.
public struct ChatHistoryPage: Sendable, Equatable, Codable {
    /// The messages in this page, ordered by ascending ``ChatMessage/seq``.
    public let messages: [ChatMessage]

    /// Whether older history exists before the first message of this page.
    public let hasMore: Bool

    /// For terminal-kind sessions, the page's command-blocks (oldest first);
    /// `nil`/absent for agent sessions, which use ``messages``. Additive and
    /// optional so existing agent payloads keep decoding unchanged.
    public let terminalBlocks: [TerminalCommandBlock]?

    /// Provider-reported token, context, and allowance state, when available.
    /// This is optional so hosts that predate usage transport decode unchanged.
    public let usage: ChatUsageTotals?

    /// Creates a history page.
    ///
    /// - Parameters:
    ///   - messages: Messages ordered by ascending seq.
    ///   - hasMore: Whether older history exists before this page.
    ///   - terminalBlocks: Command-blocks for terminal sessions, oldest first.
    public init(
        messages: [ChatMessage],
        hasMore: Bool,
        terminalBlocks: [TerminalCommandBlock]? = nil,
        usage: ChatUsageTotals? = nil
    ) {
        self.messages = messages
        self.hasMore = hasMore
        self.terminalBlocks = terminalBlocks
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
        case terminalBlocks = "terminal_blocks"
        case usage
    }
}
