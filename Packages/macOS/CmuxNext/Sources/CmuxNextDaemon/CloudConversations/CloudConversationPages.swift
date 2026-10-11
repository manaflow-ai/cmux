import Foundation

/// `cloud-conversation-snapshot` data: the head (`rev`) and the newest
/// messages, ascending; `seq` is the owner stream's sequence.
public struct CloudConversationSnapshot: Decodable, Sendable, Equatable {
    public var conversation: ConversationSummary
    public var messages: [ConversationMessage]
    public var rev: UInt64
    public var seq: UInt64

    public init(conversation: ConversationSummary, messages: [ConversationMessage], rev: UInt64, seq: UInt64) {
        self.conversation = conversation
        self.messages = messages
        self.rev = rev
        self.seq = seq
    }
}

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
