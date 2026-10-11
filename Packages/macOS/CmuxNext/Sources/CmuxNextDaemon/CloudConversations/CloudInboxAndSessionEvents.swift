import Foundation

/// `cloud-inbox-changed`: the inbox entries one owner commit wrote.
public struct CloudInboxChanged: Decodable, Sendable, Hashable {
    public var seq: UInt64
    public var transaction: String?
    public var entries: [CloudInboxEntry]
    /// The cloud account (the `sub` of the lease the daemon used) this
    /// event came through. Absent only for a lease without a readable
    /// `sub`; the app refuses such an event.
    public var account: String?

    public init(seq: UInt64, transaction: String? = nil, entries: [CloudInboxEntry], account: String? = nil) {
        self.seq = seq
        self.transaction = transaction
        self.entries = entries
        self.account = account
    }
}

/// `cloud-subscription-state` of the inbox or one conversation socket.
public struct CloudSubscriptionState: Decodable, Sendable, Hashable {
    /// `inbox` or `conversation`.
    public var scope: String
    public var conversation: String?
    /// `connecting`, `live`, `disconnected` or `closed`.
    public var state: String
    /// `signed_out`, `unauthenticated`, `unavailable` (disconnected) or `forbidden` (closed).
    public var reason: String?
    /// The cloud account (the lease's `sub`) the socket runs as; absent without one.
    public var account: String?

    public init(scope: String, conversation: String? = nil, state: String, reason: String? = nil, account: String? = nil) {
        self.scope = scope
        self.conversation = conversation
        self.state = state
        self.reason = reason
        self.account = account
    }

    public var isLive: Bool { state == "live" }
}

/// `cloud-session-needed`: the daemon asks for a new lease.
public struct CloudSessionNeeded: Decodable, Sendable, Hashable {
    /// `missing`, `expiring`, `expired` or `unauthenticated`.
    public var reason: String
    public var expiresAt: UInt64?

    public init(reason: String, expiresAt: UInt64? = nil) {
        self.reason = reason
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case reason
        case expiresAt = "expires_at"
    }
}
