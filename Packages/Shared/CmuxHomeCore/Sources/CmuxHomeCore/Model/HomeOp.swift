public import Foundation

/// A typed change the client asks an owner to make. Every op travels with an
/// idempotency key; the owner applies a key at most once.
public enum HomeOp: Hashable, Sendable {
    /// `message.send`. The key is the message's client id.
    case sendMessage(conversation: ConversationID, parts: [MessagePart])
    /// `read_cursor.set` for the signed-in user.
    case setReadCursor(conversation: ConversationID, seq: Seq)
    /// `conversation.create`: a group with these participants (humans and Chiefs).
    case createGroup(title: String, participants: [ParticipantID])
    /// `mux.create`: a new subchief owned by the signed-in user, with its DM.
    case createChief(name: String)
    /// Opens (or creates on the owner) the DM with a person reached by email
    /// or phone. If the person has no account, the owner sends an invite
    /// (email or SMS) and the conversation shows them as invited.
    case startConversation(contacts: [ContactAddress], firstMessage: [MessagePart])
    /// Invites a person to cmux without starting a conversation (the Invite button).
    case invite(contact: ContactAddress)
    /// Account inbox: pin or unpin (nil) a conversation.
    case setPinned(conversation: ConversationID, rank: Int?)
    case setMuted(conversation: ConversationID, muted: Bool)
    case addReaction(message: MessageID, conversation: ConversationID, reaction: Reaction.Kind, partIndex: Int)

    /// The stream this op writes. Its result's `rev` is a revision of this stream.
    public var stream: HomeStream {
        switch self {
        case .sendMessage(let conversation, _),
             .setReadCursor(let conversation, _),
             .addReaction(_, let conversation, _, _):
            .conversation(conversation)
        case .setPinned, .setMuted, .createGroup, .createChief, .startConversation, .invite:
            .inbox
        }
    }

    /// The conversation this op writes, when it targets one.
    public var conversation: ConversationID? {
        switch self {
        case .sendMessage(let conversation, _),
             .setReadCursor(let conversation, _),
             .setPinned(let conversation, _),
             .setMuted(let conversation, _),
             .addReaction(_, let conversation, _, _):
            conversation
        case .createGroup, .createChief, .startConversation, .invite:
            nil
        }
    }
}

/// An op with its key: the unit the intent log tracks.
public struct HomeIntent: Hashable, Sendable, Identifiable {
    public let key: IdempotencyKey
    public let op: HomeOp
    public let issuedAt: Date

    public init(key: IdempotencyKey = .make(), op: HomeOp, issuedAt: Date = Date()) {
        self.key = key
        self.op = op
        self.issuedAt = issuedAt
    }

    public var id: IdempotencyKey { key }
}

/// What the owner answered.
public struct HomeOpResult: Hashable, Sendable {
    /// Revision of the op's stream after the commit; the mirror is caught up once it reaches it.
    public var rev: Revision
    /// True when the key was already decided and this is the stored answer.
    public var replayed: Bool
    /// For ops that create or open a conversation.
    public var conversation: ConversationID?
    /// For `invite` and invited participants.
    public var invite: InviteReceipt?

    public init(rev: Revision, replayed: Bool = false, conversation: ConversationID? = nil, invite: InviteReceipt? = nil) {
        self.rev = rev
        self.replayed = replayed
        self.conversation = conversation
        self.invite = invite
    }
}

public struct InviteReceipt: Hashable, Sendable {
    public enum Channel: String, Hashable, Sendable { case email, sms }
    public var contact: ContactAddress
    public var channel: Channel
    /// The person already had an account; no invite was sent.
    public var alreadyMember: Bool

    public init(contact: ContactAddress, channel: Channel, alreadyMember: Bool) {
        self.contact = contact
        self.channel = channel
        self.alreadyMember = alreadyMember
    }
}

/// Why the owner refused an op, or why the client refused to send it.
public enum HomeRejection: Error, Hashable, Sendable {
    /// The owner is unreachable; nothing queues (U5).
    case ownerUnreachable
    case notAuthorized
    case invalid(String)
    case rateLimited(retryAfter: TimeInterval?)
    /// The outcome of a sent op is unknown; a reconnect resend settles it.
    case indeterminate

    public var isRetryable: Bool {
        switch self {
        case .ownerUnreachable, .rateLimited, .indeterminate: true
        case .notAuthorized, .invalid: false
        }
    }
}
