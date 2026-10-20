import Foundation

/// A conversation's head as its owner reports it.
public struct ConversationSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// `local` (this Mac's daemon) or `cloud` (a ConversationDO).
    public var owner: String
    public var title: String
    public var participants: [ConversationParticipant]
    public var lastSeq: UInt64
    /// Increases by one per committed op; a gap means the mirror missed one.
    public var rev: UInt64
    public var createdAt: String
    public var updatedAt: String
    public var lastMessage: ConversationMessage?
    public var readCursors: [String: UInt64]
    /// Cloud: `chief`, `dm` or `group` (absent on a local head).
    public var kind: String?
    /// Cloud: `active`, `archived` or `importing`.
    public var state: String?
    /// Cloud, a large group: how many members it has (`participants` is then a roster).
    public var memberCount: Int?
    /// Cloud: the head's `settings.wake_policy` (`auto`, `mentions`, `all`): when the Chiefs answer.
    public var wakePolicy: String?

    public init(id: String, owner: String = "local", title: String, participants: [ConversationParticipant], lastSeq: UInt64,
                rev: UInt64, createdAt: String, updatedAt: String, lastMessage: ConversationMessage? = nil,
                readCursors: [String: UInt64] = [:], kind: String? = nil, state: String? = nil, memberCount: Int? = nil,
                wakePolicy: String? = nil) {
        self.id = id
        self.owner = owner
        self.title = title
        self.participants = participants
        self.lastSeq = lastSeq
        self.rev = rev
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessage = lastMessage
        self.readCursors = readCursors
        self.kind = kind
        self.state = state
        self.memberCount = memberCount
        self.wakePolicy = wakePolicy
    }

    enum CodingKeys: String, CodingKey {
        case id, owner, title, participants, rev, kind, state
        case lastSeq = "last_seq"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastMessage = "last_message"
        case readCursors = "read_cursors"
        case memberCount = "member_count"
        case settings
    }

    /// The part of the head's `settings` the app reads.
    private struct Settings: Codable {
        var wakePolicy: String?
        enum CodingKeys: String, CodingKey { case wakePolicy = "wake_policy" }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? "local"
        title = try c.decode(String.self, forKey: .title)
        participants = try c.decode([ConversationParticipant].self, forKey: .participants)
        lastSeq = try c.decode(UInt64.self, forKey: .lastSeq)
        rev = try c.decode(UInt64.self, forKey: .rev)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        lastMessage = try c.decodeIfPresent(ConversationMessage.self, forKey: .lastMessage)
        readCursors = try c.decodeIfPresent([String: UInt64].self, forKey: .readCursors) ?? [:]
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        memberCount = try c.decodeIfPresent(Int.self, forKey: .memberCount)
        wakePolicy = (try? c.decodeIfPresent(Settings.self, forKey: .settings))?.wakePolicy
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(owner, forKey: .owner)
        try c.encode(title, forKey: .title)
        try c.encode(participants, forKey: .participants)
        try c.encode(lastSeq, forKey: .lastSeq)
        try c.encode(rev, forKey: .rev)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(lastMessage, forKey: .lastMessage)
        try c.encode(readCursors, forKey: .readCursors)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(state, forKey: .state)
        try c.encodeIfPresent(memberCount, forKey: .memberCount)
        try c.encodeIfPresent(wakePolicy.map { Settings(wakePolicy: $0) }, forKey: .settings)
    }

    /// Messages after `participant`'s read cursor.
    public func unreadCount(for participant: String) -> UInt64 {
        lastSeq - min(lastSeq, readCursors[participant] ?? 0)
    }
}
