import Foundation

// `local-conversations-v1` reads (plans/cmux-next/home.md section 2).

/// `conversation-list`: every conversation, newest `updated_at` first.
public struct ListConversationsRequest: DaemonRequest {
    public typealias Response = ConversationList
    public static let command = "conversation-list"
    public static let requiredCapability: String? = DaemonCapabilities.shared.localConversations
    public init() {}
}

/// `conversation-snapshot`: the head and the newest `tail` messages (1...500).
public struct ConversationSnapshotRequest: DaemonRequest {
    public typealias Response = ConversationSnapshot
    public static let command = "conversation-snapshot"
    public static let requiredCapability: String? = DaemonCapabilities.shared.localConversations
    public var conversation: String
    public var tail: Int
    public init(conversation: String, tail: Int) {
        self.conversation = conversation
        self.tail = min(max(tail, 1), 500)
    }
}

/// `conversation-history`: up to `limit` (1...500) messages before `beforeSeq`, ascending.
public struct ConversationHistoryRequest: DaemonRequest {
    public typealias Response = ConversationHistory
    public static let command = "conversation-history"
    public static let requiredCapability: String? = DaemonCapabilities.shared.localConversations
    public var conversation: String
    public var beforeSeq: UInt64
    public var limit: Int
    public init(conversation: String, beforeSeq: UInt64, limit: Int) {
        self.conversation = conversation
        self.beforeSeq = beforeSeq
        self.limit = min(max(limit, 1), 500)
    }
    enum CodingKeys: String, CodingKey {
        case conversation, limit
        case beforeSeq = "before_seq"
    }
}
