import Foundation

/// `cloud-session-*` data. Never carries the token.
public struct CloudSessionState: Decodable, Sendable, Equatable {
    /// `signed_out`, `active` or `expired`.
    public var state: String
    public var apiBaseURL: String?
    /// Nil for a self-hosted server's lease, which never expires.
    public var expiresAt: UInt64?
    /// `tailscale` for a self-hosted server's lease; nil for a bearer token.
    public var auth: String?

    public init(state: String, apiBaseURL: String? = nil, expiresAt: UInt64? = nil, auth: String? = nil) {
        self.state = state
        self.apiBaseURL = apiBaseURL
        self.expiresAt = expiresAt
        self.auth = auth
    }

    enum CodingKeys: String, CodingKey {
        case state, auth
        case apiBaseURL = "api_base_url"
        case expiresAt = "expires_at"
    }
}

/// A self-hosted chat server's answer to `cloud-selfhost-info`: the
/// person's user id on it (`user_ts_...`, the same for a login on every
/// server), their Tailscale login and names.
public struct CloudSelfHostInfo: Decodable, Sendable, Equatable {
    /// `selfhost`.
    public var kind: String
    public var userID: String
    /// The Tailscale login (`person@example.com`, `person@github`).
    public var login: String
    public var displayName: String?
    public var serverName: String?

    public init(kind: String = "selfhost", userID: String, login: String, displayName: String? = nil, serverName: String? = nil) {
        self.kind = kind
        self.userID = userID
        self.login = login
        self.displayName = displayName
        self.serverName = serverName
    }

    enum CodingKeys: String, CodingKey {
        case kind, login
        case userID = "user_id"
        case displayName = "display_name"
        case serverName = "server_name"
    }
}

/// `cloud-conversation-op` data. `value` is the owner's value verbatim;
/// `rev`, `seq` and `change` are lifted from it when present. `transaction`,
/// `stream` and `sequence` are the cloud request-settled barrier.
public struct CloudConversationOpResult: Decodable, Sendable, Equatable {
    /// The owner's answer to an address peer's invite in `dm.open`.
    public struct InviteOutcome: Decodable, Sendable, Equatable {
        public var ok: Bool
        public var code: String?
        public init(ok: Bool, code: String? = nil) {
            self.ok = ok
            self.code = code
        }
    }

    public var value: JSONValue
    public var rev: UInt64?
    public var seq: UInt64?
    public var change: ConversationChange?
    public var replayed: Bool
    public var transaction: String
    public var stream: String
    public var sequence: UInt64
    /// `value.conversation` of `dm.open` and `conversation.create`.
    public var conversation: ConversationSummary?
    /// `value.invite` of `dm.open` with an address peer.
    public var invite: InviteOutcome?

    public init(value: JSONValue = .null, rev: UInt64? = nil, seq: UInt64? = nil, change: ConversationChange? = nil,
                replayed: Bool = false, transaction: String = "", stream: String = "", sequence: UInt64 = 0,
                conversation: ConversationSummary? = nil, invite: InviteOutcome? = nil) {
        self.value = value
        self.rev = rev
        self.seq = seq
        self.change = change
        self.replayed = replayed
        self.transaction = transaction
        self.stream = stream
        self.sequence = sequence
        self.conversation = conversation
        self.invite = invite
    }

    private struct ValueFields: Decodable {
        var conversation: ConversationSummary?
        var invite: InviteOutcome?
    }

    enum CodingKeys: String, CodingKey { case value, rev, seq, change, replayed, transaction, stream, sequence }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
        rev = try c.decodeIfPresent(UInt64.self, forKey: .rev)
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq)
        change = try? c.decodeIfPresent(ConversationChange.self, forKey: .change)
        replayed = try c.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
        transaction = try c.decodeIfPresent(String.self, forKey: .transaction) ?? ""
        stream = try c.decodeIfPresent(String.self, forKey: .stream) ?? ""
        sequence = try c.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
        let fields = try? c.decodeIfPresent(ValueFields.self, forKey: .value)
        conversation = fields?.conversation
        invite = fields?.invite
    }
}

/// `cloud-*-subscribe` data: `connecting` with a lease, otherwise `disconnected`.
public struct CloudSubscription: Decodable, Sendable, Equatable {
    public var conversation: String?
    /// The shared socket's true state now (a `cloud-subscription-state` event follows).
    public var state: String
    public var reason: String?
    /// The cloud account (the lease's `sub`) the socket runs as; absent without one.
    public var account: String?

    public init(conversation: String? = nil, state: String, reason: String? = nil, account: String? = nil) {
        self.conversation = conversation
        self.state = state
        self.reason = reason
        self.account = account
    }

    enum CodingKeys: String, CodingKey { case conversation, state, reason, account }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decodeIfPresent(String.self, forKey: .conversation)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "disconnected"
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        account = try c.decodeIfPresent(String.self, forKey: .account)
    }
}
