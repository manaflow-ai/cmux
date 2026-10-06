import Foundation


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
