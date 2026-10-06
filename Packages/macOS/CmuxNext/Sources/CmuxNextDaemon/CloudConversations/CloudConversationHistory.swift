import Foundation


/// `cloud-conversation-history` data: one older page, ascending.
public struct CloudConversationHistory: Decodable, Sendable, Equatable {
    public var messages: [ConversationMessage]
    public var hasMore: Bool

    public init(messages: [ConversationMessage], hasMore: Bool) {
        self.messages = messages
        self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decode([ConversationMessage].self, forKey: .messages)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}
