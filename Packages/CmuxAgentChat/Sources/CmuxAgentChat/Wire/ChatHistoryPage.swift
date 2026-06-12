/// One page of transcript history, served oldest-to-newest.
public struct ChatHistoryPage: Sendable, Equatable, Codable {
    /// The messages in this page, ordered by ascending ``ChatMessage/seq``.
    public let messages: [ChatMessage]

    /// Whether older history exists before the first message of this page.
    public let hasMore: Bool

    /// Creates a history page.
    ///
    /// - Parameters:
    ///   - messages: Messages ordered by ascending seq.
    ///   - hasMore: Whether older history exists before this page.
    public init(messages: [ChatMessage], hasMore: Bool) {
        self.messages = messages
        self.hasMore = hasMore
    }

    private enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
    }
}
