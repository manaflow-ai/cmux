public import Foundation

/// What the conversation owner publishes about one conversation (the
/// `Summary` of the wire contract), plus the account-inbox fields the
/// user's inbox owner adds (pin, mute).
public struct ConversationSummary: Hashable, Sendable, Codable, Identifiable {
    public enum Owner: String, Hashable, Sendable, Codable {
        /// Cloud conversation (shared, reachable from iPhone without the Mac).
        case cloud
        /// Local-only conversation owned by one Mac ("this Mac only").
        case local
    }

    public let id: ConversationID
    public var owner: Owner
    /// Empty means "derive from participants".
    public var title: String
    public var participants: [Participant]
    public var lastSeq: Seq
    public var rev: Revision
    public var createdAt: Date
    public var updatedAt: Date
    public var lastMessage: Message?
    public var readCursors: [ParticipantID: Seq]
    /// When each participant's cursor last moved (for "Read 9:41" receipts).
    public var readCursorTimes: [ParticipantID: Date]
    /// Account inbox state (owned by the user's inbox owner, not the conversation).
    public var pinRank: Int?
    public var muted: Bool
    /// The owner's `preview_attachments` for the last message, when the
    /// source has only the inbox entry (no `lastMessage`). Rows derive it
    /// from `lastMessage` otherwise.
    public var previewAttachments: AttachmentPreview?
    /// Unread messages that mention the user (the inbox owner's `mentions`).
    public var mentionCount: Int
    /// The kind the owner declared (`group`, `dm`, `chief`), when it says. A group stays a group
    /// when it shrinks to one other person; nil derives the kind from the participants.
    public var declaredKind: Kind?
    /// A large Cloud group's member count (`member_count`): its `participants` are then only a
    /// roster. Nil when `participants` lists everyone.
    public var memberCount: Int?
    /// When the group's Chiefs answer (the owner's `settings.wake_policy`); nil when the owner
    /// names none (a local conversation, or an owner before settings), which means ``ChiefReplyPolicy/default``.
    public var chiefReplies: ChiefReplyPolicy?

    public init(
        id: ConversationID,
        owner: Owner = .cloud,
        title: String = "",
        participants: [Participant],
        lastSeq: Seq = 0,
        rev: Revision = 0,
        createdAt: Date,
        updatedAt: Date,
        lastMessage: Message? = nil,
        readCursors: [ParticipantID: Seq] = [:],
        readCursorTimes: [ParticipantID: Date] = [:],
        pinRank: Int? = nil,
        muted: Bool = false,
        previewAttachments: AttachmentPreview? = nil,
        mentionCount: Int = 0,
        declaredKind: Kind? = nil,
        memberCount: Int? = nil,
        chiefReplies: ChiefReplyPolicy? = nil
    ) {
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
        self.readCursorTimes = readCursorTimes
        self.pinRank = pinRank
        self.muted = muted
        self.previewAttachments = previewAttachments
        self.mentionCount = mentionCount
        self.declaredKind = declaredKind
        self.memberCount = memberCount
        self.chiefReplies = chiefReplies
    }

    public enum Kind: String, Hashable, Sendable, Codable {
        /// A one-to-one conversation with one of my Chiefs.
        case chief
        /// One other human.
        case direct
        /// Three or more participants, or several Chiefs.
        case group
    }

    /// Classifies from the participants other than `me`. A Chief's conversation its owner shared
    /// with teammates stays the owner's Chief line; a teammate sees it as a group.
    public func kind(me: ParticipantID) -> Kind {
        if declaredKind == .group { return .group }
        if declaredKind == .chief, isMyChiefLine(me: me) { return .chief }
        let others = participants.filter { $0.id != me }
        if others.count == 1, let other = others.first {
            return other.isChief ? .chief : .direct
        }
        return .group
    }

    /// A Chief's own conversation whose Chief is mine (the owner may share it with teammates).
    public func isMyChiefLine(me: ParticipantID) -> Bool {
        declaredKind == .chief && participants.contains { $0.isChief && $0.ownerUser == me }
    }

    /// Whether the transcript names each message's sender: in a group, and in my Chief's
    /// conversation once I shared it with someone.
    public func showsSenderNames(me: ParticipantID) -> Bool {
        switch kind(me: me) {
        case .group: true
        case .chief: participants.contains { $0.kind == .human && $0.id != me }
        case .direct: false
        }
    }

    /// The title a list row shows: the explicit title, else the other
    /// participants' names.
    public func displayTitle(me: ParticipantID) -> String {
        if !title.isEmpty, !title.isHomeInternalID { return title }
        let names = participants.filter { $0.id != me }.map(\.visibleName).filter { !$0.isEmpty }
        return names.isEmpty ? "" : ListFormatter.localizedString(byJoining: names)
    }

    /// Messages after my read cursor, without my own: my newest message
    /// counts as read up to its seq (Messages and Slack: a person who
    /// writes has seen the conversation). An owner that moves the sender's
    /// cursor on send (the mock, `DaemonHomeSource`) gives an exact count;
    /// for one that does not, my own messages between other people's still
    /// count until my cursor passes them.
    public func unreadCount(me: ParticipantID) -> Int {
        var cursor = readCursors[me] ?? 0
        if let lastMessage, lastMessage.author == me { cursor = max(cursor, lastMessage.seq) }
        return lastSeq > cursor ? Int(lastSeq - cursor) : 0
    }

    public var hasInvitedParticipant: Bool { participants.contains { $0.membership == .invited } }
}

/// The account inbox: every conversation the user is in.
public struct InboxSnapshot: Hashable, Sendable {
    public var me: Participant
    public var conversations: [ConversationSummary]
    public var rev: Revision

    public init(me: Participant, conversations: [ConversationSummary], rev: Revision) {
        self.me = me
        self.conversations = conversations
        self.rev = rev
    }
}

/// A contiguous window of a conversation's messages, ascending by seq.
public struct ConversationPage: Hashable, Sendable {
    public var conversation: ConversationSummary
    public var messages: [Message]
    /// The owner's stats of the thread roots in `messages` (empty from an
    /// owner without thread stats).
    public var threads: [ThreadSummary]

    public init(conversation: ConversationSummary, messages: [Message], threads: [ThreadSummary] = []) {
        self.conversation = conversation
        self.messages = messages
        self.threads = threads
    }
}
