public import Foundation

/// A normalized conversation thread, channel, chat, or source grouping.
public struct InboxThread: Codable, Equatable, Identifiable, Sendable {
    /// Local stable thread id.
    public let threadID: String
    /// Source service for the thread.
    public let source: InboxSource
    /// Source-specific account id.
    public let accountID: String
    /// Source thread, channel, chat, or conversation id.
    public let externalThreadID: String
    /// Participants currently known for the thread.
    public var participants: [InboxParticipant]
    /// Human-readable thread title.
    public var title: String
    /// Unread item count computed from local items.
    public var unreadCount: Int
    /// Most recent activity timestamp.
    public var lastActivityAt: Date
    /// Whether the thread is muted locally or at the source.
    public var isMuted: Bool
    /// Whether the thread is pinned locally or at the source.
    public var isPinned: Bool
    /// Whether the thread is archived locally or at the source.
    public var isArchived: Bool
    /// Optional source deep link.
    public var externalURL: String?
    /// Source-specific non-secret metadata.
    public var metadata: [String: String]

    /// Stable identity used by SwiftUI lists.
    public var id: String { threadID }

    /// Creates a normalized thread record.
    public init(
        threadID: String,
        source: InboxSource,
        accountID: String,
        externalThreadID: String,
        participants: [InboxParticipant],
        title: String,
        unreadCount: Int = 0,
        lastActivityAt: Date,
        isMuted: Bool = false,
        isPinned: Bool = false,
        isArchived: Bool = false,
        externalURL: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.threadID = threadID
        self.source = source
        self.accountID = accountID
        self.externalThreadID = externalThreadID
        self.participants = participants
        self.title = title
        self.unreadCount = unreadCount
        self.lastActivityAt = lastActivityAt
        self.isMuted = isMuted
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.externalURL = externalURL
        self.metadata = metadata
    }
}
