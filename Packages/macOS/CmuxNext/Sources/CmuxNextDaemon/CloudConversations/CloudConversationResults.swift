import Foundation

/// `cloud-session-*` data. Never carries the token.
public struct CloudSessionState: Decodable, Sendable, Equatable {
    /// `signed_out`, `active` or `expired`.
    public var state: String
    public var apiBaseURL: String?
    public var expiresAt: UInt64?

    public init(state: String, apiBaseURL: String? = nil, expiresAt: UInt64? = nil) {
        self.state = state
        self.apiBaseURL = apiBaseURL
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case state
        case apiBaseURL = "api_base_url"
        case expiresAt = "expires_at"
    }
}

/// One entry of the account inbox (home-core `InboxEntry`, owner UserDO).
/// Conversation-owned fields are a projection guarded by `rev`; pin, mute,
/// archive and the unread mark belong to the user.
public struct CloudInboxEntry: Decodable, Sendable, Hashable {
    public var conversation: String
    public var rev: UInt64
    /// `chief`, `dm` or `group`.
    public var kind: String
    public var title: String
    public var lastSeq: UInt64
    public var lastAt: String
    /// 240 characters, author and text.
    public var preview: String
    public var dmPeer: String?
    /// The user left or was removed.
    public var removed: Bool
    /// Messages after the user's cursor, excluding the user's own.
    public var unread: UInt64
    public var mentions: UInt64
    public var pinned: Bool
    public var pinPosition: Int?
    public var muted: Bool
    public var mutedUntil: UInt64?
    public var archived: Bool
    public var markedUnread: Bool

    public init(conversation: String, rev: UInt64, kind: String, title: String = "", lastSeq: UInt64, lastAt: String,
                preview: String = "", dmPeer: String? = nil, removed: Bool = false, unread: UInt64 = 0, mentions: UInt64 = 0,
                pinned: Bool = false, pinPosition: Int? = nil, muted: Bool = false, mutedUntil: UInt64? = nil,
                archived: Bool = false, markedUnread: Bool = false) {
        self.conversation = conversation
        self.rev = rev
        self.kind = kind
        self.title = title
        self.lastSeq = lastSeq
        self.lastAt = lastAt
        self.preview = preview
        self.dmPeer = dmPeer
        self.removed = removed
        self.unread = unread
        self.mentions = mentions
        self.pinned = pinned
        self.pinPosition = pinPosition
        self.muted = muted
        self.mutedUntil = mutedUntil
        self.archived = archived
        self.markedUnread = markedUnread
    }

    enum CodingKeys: String, CodingKey {
        case conversation, rev, kind, title, preview, removed, unread, mentions, pinned, muted, archived
        case lastSeq = "last_seq"
        case lastAt = "last_at"
        case dmPeer = "dm_peer"
        case pinPosition = "pin_position"
        case mutedUntil = "muted_until"
        case markedUnread = "marked_unread"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decode(String.self, forKey: .conversation)
        rev = try c.decode(UInt64.self, forKey: .rev)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "group"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        lastSeq = try c.decodeIfPresent(UInt64.self, forKey: .lastSeq) ?? 0
        lastAt = try c.decodeIfPresent(String.self, forKey: .lastAt) ?? ""
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        dmPeer = try c.decodeIfPresent(String.self, forKey: .dmPeer)
        removed = try c.decodeIfPresent(Bool.self, forKey: .removed) ?? false
        unread = try c.decodeIfPresent(UInt64.self, forKey: .unread) ?? 0
        mentions = try c.decodeIfPresent(UInt64.self, forKey: .mentions) ?? 0
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        pinPosition = try c.decodeIfPresent(Int.self, forKey: .pinPosition)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        mutedUntil = try c.decodeIfPresent(UInt64.self, forKey: .mutedUntil)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        markedUnread = try c.decodeIfPresent(Bool.self, forKey: .markedUnread) ?? false
    }

    /// Whether the entry belongs in the visible inbox.
    public var isListed: Bool { !removed && !archived }
}

/// `cloud-inbox-list` data. `revision` is the owner's opaque read revision.
public struct CloudInboxList: Decodable, Sendable, Equatable {
    public var entries: [CloudInboxEntry]
    public var revision: JSONValue?

    public init(entries: [CloudInboxEntry], revision: JSONValue? = nil) {
        self.entries = entries
        self.revision = revision
    }
}

/// `cloud-conversation-snapshot` data: the head (`rev`) and the newest
/// messages, ascending; `seq` is the owner stream's sequence.
public struct CloudConversationSnapshot: Decodable, Sendable, Equatable {
    public var conversation: ConversationSummary
    public var messages: [ConversationMessage]
    public var rev: UInt64
    public var seq: UInt64

    public init(conversation: ConversationSummary, messages: [ConversationMessage], rev: UInt64, seq: UInt64) {
        self.conversation = conversation
        self.messages = messages
        self.rev = rev
        self.seq = seq
    }
}

/// `cloud-conversation-history` data: one older page, ascending.
public struct CloudConversationHistory: Decodable, Sendable, Equatable {
    public var messages: [ConversationMessage]
    public var hasMore: Bool

    public init(messages: [ConversationMessage], hasMore: Bool) {
        self.messages = messages
        self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decode([ConversationMessage].self, forKey: .messages)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
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
    public var state: String

    public init(conversation: String? = nil, state: String) {
        self.conversation = conversation
        self.state = state
    }

    enum CodingKeys: String, CodingKey { case conversation, state }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decodeIfPresent(String.self, forKey: .conversation)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "disconnected"
    }
}
