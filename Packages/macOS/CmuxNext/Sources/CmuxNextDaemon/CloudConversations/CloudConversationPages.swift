import Foundation

/// `cloud-conversation-snapshot` data: the head (`rev`) and the newest
/// messages, ascending; `seq` is the owner stream's sequence.
public struct CloudConversationSnapshot: Decodable, Sendable, Equatable {
    public var conversation: ConversationSummary
    public var messages: [ConversationMessage]
    public var rev: UInt64
    public var seq: UInt64
    /// The owner's stats of the thread roots in `messages` (`conversation-thread-v1`).
    public var threads: [ConversationThreadSummary]

    public init(conversation: ConversationSummary, messages: [ConversationMessage], rev: UInt64, seq: UInt64,
                threads: [ConversationThreadSummary] = []) {
        self.conversation = conversation
        self.messages = messages
        self.rev = rev
        self.seq = seq
        self.threads = threads
    }

    enum CodingKeys: String, CodingKey { case conversation, messages, rev, seq, threads }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decode(ConversationSummary.self, forKey: .conversation)
        messages = try c.decode([ConversationMessage].self, forKey: .messages)
        rev = try c.decode(UInt64.self, forKey: .rev)
        seq = try c.decode(UInt64.self, forKey: .seq)
        threads = try c.decodeIfPresent([ConversationThreadSummary].self, forKey: .threads) ?? []
    }
}

/// `cloud-conversation-history` data: one older page, ascending.
public struct CloudConversationHistory: Decodable, Sendable, Equatable {
    public var messages: [ConversationMessage]
    public var hasMore: Bool
    /// The owner's stats of the thread roots in `messages` (`conversation-thread-v1`).
    public var threads: [ConversationThreadSummary]

    public init(messages: [ConversationMessage], hasMore: Bool, threads: [ConversationThreadSummary] = []) {
        self.messages = messages
        self.hasMore = hasMore
        self.threads = threads
    }

    enum CodingKeys: String, CodingKey {
        case messages, threads
        case hasMore = "has_more"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decode([ConversationMessage].self, forKey: .messages)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        threads = try c.decodeIfPresent([ConversationThreadSummary].self, forKey: .threads) ?? []
    }
}
