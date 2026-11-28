import Foundation

// `conversation-thread-v1` (cx-59n8.6): the owner read of one thread and the
// owner's stats of thread roots on snapshot and history pages. The cloud
// proxy's `cloud-conversation-thread` passes the same value through.

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
