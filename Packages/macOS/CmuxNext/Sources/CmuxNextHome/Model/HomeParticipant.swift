public import Foundation

/// One member of a conversation: the Mac's user, another person or an agent.
public nonisolated struct HomeParticipant: Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    /// The user of this Mac (outgoing bubbles).
    public var isMe: Bool
    public var isAgent: Bool

    public init(id: String, displayName: String, isMe: Bool = false, isAgent: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isMe = isMe
        self.isAgent = isAgent
    }
}

/// One row of the conversation list.
public nonisolated struct HomeConversationSummary: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var participants: [HomeParticipant]
    public var lastMessagePreview: String
    public var updatedAt: Date
    public var unreadCount: Int
    /// Where the conversation lives, e.g. "This Mac only" for a local owner. Nil hides it.
    public var ownerLabel: String?

    public init(id: String, title: String, participants: [HomeParticipant], lastMessagePreview: String = "",
                updatedAt: Date, unreadCount: Int = 0, ownerLabel: String? = nil) {
        self.id = id
        self.title = title
        self.participants = participants
        self.lastMessagePreview = lastMessagePreview
        self.updatedAt = updatedAt
        self.unreadCount = unreadCount
        self.ownerLabel = ownerLabel
    }
}
