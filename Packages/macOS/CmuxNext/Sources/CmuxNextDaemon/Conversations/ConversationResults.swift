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
    public init(conversation: ConversationSummary, messages: [ConversationMessage]) {
        self.conversation = conversation
        self.messages = messages
    }
}

/// `conversation-history` data: one older page, ascending.
public struct ConversationHistory: Decodable, Sendable, Equatable {
    public var messages: [ConversationMessage]
    public init(messages: [ConversationMessage]) { self.messages = messages }
}
