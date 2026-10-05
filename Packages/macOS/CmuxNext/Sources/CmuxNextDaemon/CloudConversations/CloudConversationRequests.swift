import Foundation

// `cloud-conversations-v1` commands (plans/cmux-next/home-cloud-proxy.md
// section 4). The daemon only transports: ConversationDO owns each cloud
// conversation and UserDO owns the inbox. Trusted local connections only.

/// `cloud-session-set`: leases the signed-in account's access token to the
/// daemon. The daemon keeps it in memory only and never returns it.
public struct CloudSessionSetRequest: DaemonRequest, CustomStringConvertible {
    public typealias Response = CloudSessionState
    public static let command = "cloud-session-set"
    /// An https origin, or http with a loopback host; no path.
    public var apiBaseURL: String
    public var accessToken: String
    /// Unix milliseconds.
    public var expiresAt: UInt64
    /// Forwarded as `x-cmux-client-version`.
    public var clientVersion: String?

    public init(apiBaseURL: String, accessToken: String, expiresAt: UInt64, clientVersion: String? = nil) {
        self.apiBaseURL = apiBaseURL
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.clientVersion = clientVersion
    }

    /// Never prints the token.
    public var description: String { "cloud-session-set(\(apiBaseURL), expires_at: \(expiresAt))" }
}

/// `cloud-session-clear`: ends the lease (sign-out, account switch).
public struct CloudSessionClearRequest: DaemonRequest {
    public typealias Response = CloudSessionState
    public static let command = "cloud-session-clear"
    public init() {}
}

/// `cloud-session-status`.
public struct CloudSessionStatusRequest: DaemonRequest {
    public typealias Response = CloudSessionState
    public static let command = "cloud-session-status"
    public init() {}
}

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

/// `cloud-inbox-subscribe`: the daemon's shared inbox socket for this connection.
public struct CloudInboxSubscribeRequest: DaemonRequest {
    public typealias Response = CloudSubscription
    public static let command = "cloud-inbox-subscribe"
    public init() {}
}

/// `cloud-inbox-unsubscribe`.
public struct CloudInboxUnsubscribeRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "cloud-inbox-unsubscribe"
    public init() {}
}

/// `cloud-conversation-subscribe`: at most 64 per daemon (`too_many_subscriptions`).
public struct CloudConversationSubscribeRequest: DaemonRequest {
    public typealias Response = CloudSubscription
    public static let command = "cloud-conversation-subscribe"
    public static let maxSubscriptions = 64
    public var conversation: String
    public init(conversation: String) { self.conversation = conversation }
}

/// `cloud-conversation-unsubscribe`.
public struct CloudConversationUnsubscribeRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "cloud-conversation-unsubscribe"
    public var conversation: String
    public init(conversation: String) { self.conversation = conversation }
}
