import Foundation

/// `conversation-list` data.
public struct ConversationList: Decodable, Sendable, Equatable {
    public var conversations: [ConversationSummary]
    public init(conversations: [ConversationSummary]) { self.conversations = conversations }
}

/// `conversation-snapshot` data: the head and the newest messages, ascending.
public struct ConversationSnapshot: Decodable, Sendable, Equatable {
    public var conversation: ConversationSummary
    public var messages: [ConversationMessage]
    /// The owner's stats of the thread roots in `messages` (`conversation-thread-v1`).
    public var threads: [ConversationThreadSummary]
    public init(conversation: ConversationSummary, messages: [ConversationMessage], threads: [ConversationThreadSummary] = []) {
        self.conversation = conversation
        self.messages = messages
        self.threads = threads
    }
    enum CodingKeys: String, CodingKey { case conversation, messages, threads }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decode(ConversationSummary.self, forKey: .conversation)
        messages = try c.decode([ConversationMessage].self, forKey: .messages)
        threads = try c.decodeIfPresent([ConversationThreadSummary].self, forKey: .threads) ?? []
    }
}

/// `conversation-history` data: one older page, ascending.
public struct ConversationHistory: Decodable, Sendable, Equatable {
    public var messages: [ConversationMessage]
    /// The owner's stats of the thread roots in `messages` (`conversation-thread-v1`).
    public var threads: [ConversationThreadSummary]
    public init(messages: [ConversationMessage], threads: [ConversationThreadSummary] = []) {
        self.messages = messages
        self.threads = threads
    }
    enum CodingKeys: String, CodingKey { case messages, threads }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decode([ConversationMessage].self, forKey: .messages)
        threads = try c.decodeIfPresent([ConversationThreadSummary].self, forKey: .threads) ?? []
    }
}
