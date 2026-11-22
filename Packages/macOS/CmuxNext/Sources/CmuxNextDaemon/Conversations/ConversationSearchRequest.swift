import Foundation

/// `conversation-search` (`conversation-search-v1`): Home-only search over the
/// text of the caller's conversations, newest first (the shared read model).
public struct ConversationSearchRequest: DaemonRequest {
    public struct Hit: Decodable, Sendable, Equatable {
        public var conversation: String
        public var title: String
        public var seq: UInt64
        public var messageID: String
        public var author: String
        public var createdAt: String
        public var snippet: String
        enum CodingKeys: String, CodingKey {
            case conversation, title, seq, author, snippet
            case messageID = "message_id"
            case createdAt = "created_at"
        }
    }
    public struct Response: Decodable, Sendable, Equatable {
        public var hits: [Hit]
    }
    public static let command = "conversation-search"
    public static let requiredCapability: String? = DaemonCapabilities.shared.conversationSearch
    public var query: String
    public var limit: Int
    public init(query: String, limit: Int) {
        self.query = query
        self.limit = limit
    }
}
