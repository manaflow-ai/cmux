import Foundation

// `conversation-thread-v1` (cx-59n8.6): the owner read of one thread and the
// owner's stats of thread roots on snapshot and history pages. The cloud
// proxy's `cloud-conversation-thread` passes the same value through.

/// The owner's stats of one thread root, counted at read time.
public struct ConversationThreadSummary: Decodable, Sendable, Equatable {
    public var root: String
    public var replyCount: Int
    public var lastReplySeq: UInt64?
    public var lastReplyAt: String?
    /// The first three distinct reply authors, oldest reply first.
    public var authors: [String]

    public init(root: String, replyCount: Int, lastReplySeq: UInt64? = nil, lastReplyAt: String? = nil, authors: [String] = []) {
        self.root = root
        self.replyCount = replyCount
        self.lastReplySeq = lastReplySeq
        self.lastReplyAt = lastReplyAt
        self.authors = authors
    }

    enum CodingKeys: String, CodingKey {
        case root, authors
        case replyCount = "reply_count"
        case lastReplySeq = "last_reply_seq"
        case lastReplyAt = "last_reply_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decode(String.self, forKey: .root)
        replyCount = try c.decode(Int.self, forKey: .replyCount)
        lastReplySeq = try c.decodeIfPresent(UInt64.self, forKey: .lastReplySeq)
        lastReplyAt = try c.decodeIfPresent(String.self, forKey: .lastReplyAt)
        authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
    }
}

/// `conversation-thread` / `cloud-conversation-thread` data: the root, the
/// replies after `after_seq` (ascending), and the stats of the whole thread.
public struct ConversationThread: Decodable, Sendable, Equatable {
    public var root: ConversationMessage
    public var replies: [ConversationMessage]
    public var hasMore: Bool
    public var thread: ConversationThreadSummary

    public init(root: ConversationMessage, replies: [ConversationMessage], hasMore: Bool, thread: ConversationThreadSummary) {
        self.root = root
        self.replies = replies
        self.hasMore = hasMore
        self.thread = thread
    }

    enum CodingKeys: String, CodingKey {
        case root, replies, thread
        case hasMore = "has_more"
    }
}

/// `conversation-thread`: the root and up to `limit` (1...500) replies after `afterSeq`.
public struct ConversationThreadRequest: DaemonRequest {
    public typealias Response = ConversationThread
    public static let command = "conversation-thread"
    public static let requiredCapability: String? = DaemonCapability.conversationThread.rawValue
    public static let maxLimit = 500
    public var conversation: String
    public var root: String
    public var afterSeq: UInt64
    public var limit: Int
    public init(conversation: String, root: String, afterSeq: UInt64, limit: Int) {
        self.conversation = conversation
        self.root = root
        self.afterSeq = afterSeq
        self.limit = min(max(limit, 1), Self.maxLimit)
    }
    enum CodingKeys: String, CodingKey {
        case conversation, root, limit
        case afterSeq = "after_seq"
    }
}
