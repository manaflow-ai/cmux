import Foundation

// `cloud-conversations-v1` commands (plans/cmux-next/home-cloud-proxy.md
// section 4). The daemon only transports: ConversationDO owns each cloud
// conversation and UserDO owns the inbox. Trusted local connections only.

/// `cloud-conversation-op`: one typed op, forwarded with the client's key
/// and origin. A retry with the same key answers `replayed: true`.
public struct CloudConversationOpRequest: DaemonRequest {
    public typealias Response = CloudConversationOpResult
    public static let command = "cloud-conversation-op"
    /// Required, except for `dm.open` and `conversation.create`, which must not carry it.
    public var conversation: String?
    /// 1...256 characters, sent unchanged.
    public var idempotencyKey: String
    /// `user|cli|mcp|script|remote`; absent is `cli`.
    public var origin: String?
    public var op: CloudConversationOp

    public init(conversation: String?, idempotencyKey: String, origin: String? = "user", op: CloudConversationOp) {
        self.conversation = conversation
        self.idempotencyKey = idempotencyKey
        self.origin = origin
        self.op = op
    }
}

extension CloudConversationSubscribeRequest {
    public static let maxSubscriptions = 64
}
