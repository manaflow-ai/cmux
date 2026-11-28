import Foundation

extension ConversationSearchRequest {
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
}
