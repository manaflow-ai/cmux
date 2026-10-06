
/// `cloud-conversation-history`: up to `limit` (1...200) messages before `beforeSeq`, ascending.

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
