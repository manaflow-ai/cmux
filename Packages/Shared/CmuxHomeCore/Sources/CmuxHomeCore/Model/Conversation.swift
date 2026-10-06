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
        mentionCount: Int = 0
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
    }

    public enum Kind: Hashable, Sendable {
        /// A one-to-one conversation with one of my Chiefs.
        case chief
        /// One other human.
        case direct
        /// Three or more participants, or several Chiefs.
        case group
    }

    /// Classifies from the participants other than `me`.
    public func kind(me: ParticipantID) -> Kind {
        let others = participants.filter { $0.id != me }
        if others.count == 1, let other = others.first {
            return other.isChief ? .chief : .direct
        }
        return .group
    }

    /// The title a list row shows: the explicit title, else the other
    /// participants' names.
    public func displayTitle(me: ParticipantID) -> String {
        if !title.isEmpty { return title }
        let names = participants.filter { $0.id != me }.map(\.displayName)
        return names.isEmpty ? "" : ListFormatter.localizedString(byJoining: names)
    }

    public func unreadCount(me: ParticipantID) -> Int {
        let cursor = readCursors[me] ?? 0
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

    public init(conversation: ConversationSummary, messages: [Message]) {
        self.conversation = conversation
        self.messages = messages
    }
}
