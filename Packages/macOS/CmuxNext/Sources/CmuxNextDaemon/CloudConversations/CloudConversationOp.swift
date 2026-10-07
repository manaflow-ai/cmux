import Foundation

/// An email address or phone number (E.164) that is not yet a cmux user.
public enum CloudAddress: Sendable, Hashable, Encodable {
    case email(String)
    case phone(String)

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        switch self {
        case .email(let value): try c.encode(value, forKey: DynamicKey("email"))
        case .phone(let value): try c.encode(value, forKey: DynamicKey("phone"))
        }
    }
}

/// Who `dm.open` opens a DM with: a participant id or an address.
public enum CloudPeer: Sendable, Hashable, Encodable {
    case participant(String)
    case address(CloudAddress)

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .participant(let id):
            var c = encoder.singleValueContainer()
            try c.encode(id)
        case .address(let address):
            try address.encode(to: encoder)
        }
    }
}

/// The op kinds `cloud-conversation-op` forwards (home-cloud-proxy.md section
/// 4). Tagged by `kind`; the other fields are the owner's params, unchanged.
/// The daemon refuses every other kind with `unsupported_op`.
public enum CloudConversationOp: Encodable, Sendable, Hashable {
    case dmOpen(peer: CloudPeer)
    case create(title: String?, participants: [ConversationParticipant])
    case addParticipant(ConversationParticipant)
    case removeParticipant(String)
    /// The idempotency key must equal `clientMsgID`.
    case send(clientMsgID: String, parts: [ConversationPart], replyTo: ConversationPartRef?)
    case edit(messageID: String, parts: [ConversationPart])
    case retract(messageID: String)
    case addReaction(messageID: String, partIndex: Int, kind: ConversationReactionKind)
    case removeReaction(messageID: String, partIndex: Int, kind: ConversationReactionKind)
    case setReadCursor(seq: UInt64)
    case setTitle(String)
    case createInvite(address: CloudAddress, displayName: String, locale: String?)

    public var kindName: String {
        switch self {
        case .dmOpen: "dm.open"
        case .create: "conversation.create"
        case .addParticipant: "participants.add"
        case .removeParticipant: "participants.remove"
        case .send: "message.send"
        case .edit: "message.edit"
        case .retract: "message.retract"
        case .addReaction: "reaction.add"
        case .removeReaction: "reaction.remove"
        case .setReadCursor: "read_cursor.set"
        case .setTitle: "title.set"
        case .createInvite: "invite.create"
        }
    }

    /// `dm.open` and `conversation.create` name no conversation; every other kind needs one.
    public var namesConversation: Bool {
        switch self {
        case .dmOpen, .create: false
        default: true
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(kindName, forKey: DynamicKey("kind"))
        switch self {
        case .dmOpen(let peer):
            try c.encode(peer, forKey: DynamicKey("peer"))
        case .create(let title, let participants):
            try c.encodeIfPresent(title, forKey: DynamicKey("title"))
            try c.encode(participants, forKey: DynamicKey("participants"))
        case .addParticipant(let participant):
            try c.encode(participant, forKey: DynamicKey("participant"))
        case .removeParticipant(let participant):
            try c.encode(participant, forKey: DynamicKey("participant"))
        case .send(let clientMsgID, let parts, let replyTo):
            try c.encode(clientMsgID, forKey: DynamicKey("client_msg_id"))
            try c.encode(parts, forKey: DynamicKey("parts"))
            try c.encodeIfPresent(replyTo, forKey: DynamicKey("reply_to"))
        case .edit(let messageID, let parts):
            try c.encode(messageID, forKey: DynamicKey("message_id"))
            try c.encode(parts, forKey: DynamicKey("parts"))
        case .retract(let messageID):
            try c.encode(messageID, forKey: DynamicKey("message_id"))
        case .addReaction(let messageID, let partIndex, let kind), .removeReaction(let messageID, let partIndex, let kind):
            try c.encode(messageID, forKey: DynamicKey("message_id"))
            try c.encode(partIndex, forKey: DynamicKey("part_index"))
            try c.encode(kind, forKey: DynamicKey("reaction"))
        case .setReadCursor(let seq):
            try c.encode(seq, forKey: DynamicKey("seq"))
        case .setTitle(let title):
            try c.encode(title, forKey: DynamicKey("title"))
        case .createInvite(let address, let displayName, let locale):
            try c.encode(address, forKey: DynamicKey("address"))
            try c.encode(displayName, forKey: DynamicKey("display_name"))
            try c.encodeIfPresent(locale, forKey: DynamicKey("locale"))
        }
    }
}
