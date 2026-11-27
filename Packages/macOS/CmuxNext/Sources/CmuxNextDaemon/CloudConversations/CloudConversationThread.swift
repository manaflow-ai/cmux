import Foundation

/// `cloud-conversation-thread`: ConversationDO's `conversation.thread` read
/// through the proxy (cx-59n8.6), up to `limit` (1...200) replies after `afterSeq`.
public struct CloudConversationThreadRequest: DaemonRequest {
    public typealias Response = ConversationThread
    public static let command = "cloud-conversation-thread"
    public static let requiredCapability: String? = DaemonCapability.conversationThread.rawValue
    public static let maxLimit = 200
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
