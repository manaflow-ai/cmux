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

    /// Whether the Mac has a transcript source for this page's session.
    public let transcriptAvailability: ChatTranscriptAvailability

    /// Creates a history page.
    ///
    /// - Parameters:
    ///   - messages: Messages ordered by ascending seq.
    ///   - hasMore: Whether older history exists before this page.
    ///   - terminalBlocks: Command-blocks for terminal sessions, oldest first.
    ///   - transcriptAvailability: Whether the transcript source is known.
    public init(
        messages: [ChatMessage],
        hasMore: Bool,
        terminalBlocks: [TerminalCommandBlock]? = nil,
        transcriptAvailability: ChatTranscriptAvailability = .available
    ) {
        self.messages = messages
        self.hasMore = hasMore
        self.terminalBlocks = terminalBlocks
        self.transcriptAvailability = transcriptAvailability
    }

    private enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
        case terminalBlocks = "terminal_blocks"
        case transcriptAvailability = "transcript_availability"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
        terminalBlocks = try container.decodeIfPresent([TerminalCommandBlock].self, forKey: .terminalBlocks)
        transcriptAvailability = try container.decodeIfPresent(
            ChatTranscriptAvailability.self,
            forKey: .transcriptAvailability
        ) ?? .available
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messages, forKey: .messages)
        try container.encode(hasMore, forKey: .hasMore)
        try container.encodeIfPresent(terminalBlocks, forKey: .terminalBlocks)
        try container.encode(transcriptAvailability, forKey: .transcriptAvailability)
    }
}
