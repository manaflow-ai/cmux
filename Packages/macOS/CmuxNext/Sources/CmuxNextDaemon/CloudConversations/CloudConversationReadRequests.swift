import Foundation

// `cloud-conversations-v1` commands (plans/cmux-next/home-cloud-proxy.md
// section 4). The daemon only transports: ConversationDO owns each cloud
// conversation and UserDO owns the inbox. Trusted local connections only.

/// `cloud-inbox-list`: the account inbox (UserDO `inbox.list`).
public struct CloudInboxListRequest: DaemonRequest {
    public typealias Response = CloudInboxList
    public static let command = "cloud-inbox-list"
    public static let maxLimit = 200
    public var limit: Int?
    public var includeArchived: Bool?
    public init(limit: Int? = nil, includeArchived: Bool? = nil) {
        self.limit = limit.map { min(max($0, 1), Self.maxLimit) }
        self.includeArchived = includeArchived
    }
}

/// `cloud-conversation-snapshot`: the head and the newest `tail` (1...50) messages.
public struct CloudConversationSnapshotRequest: DaemonRequest {
    public typealias Response = CloudConversationSnapshot
    public static let command = "cloud-conversation-snapshot"
    /// The owner returns at most this many messages.
    public static let maxTail = 50
    public var conversation: String
    public var tail: Int
    public init(conversation: String, tail: Int) {
        self.conversation = conversation
        self.tail = min(max(tail, 1), Self.maxTail)
    }
}

/// `cloud-conversation-history`: up to `limit` (1...200) messages before `beforeSeq`, ascending.
public struct CloudConversationHistoryRequest: DaemonRequest {
    public typealias Response = CloudConversationHistory
    public static let command = "cloud-conversation-history"
    public static let maxLimit = 200
    public var conversation: String
    public var beforeSeq: UInt64
    public var limit: Int
    public init(conversation: String, beforeSeq: UInt64, limit: Int) {
        self.conversation = conversation
        self.beforeSeq = beforeSeq
        self.limit = min(max(limit, 1), Self.maxLimit)
    }
}
