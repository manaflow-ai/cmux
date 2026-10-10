import Foundation

/// A typed op on one conversation (`conversation-op`). The owner validates it
/// with the shared reducer and applies it once per idempotency key.
public enum ConversationOp: Encodable, Sendable, Hashable {
    /// The idempotency key must equal `clientMsgID`.
    case send(clientMsgID: String, parts: [ConversationPart], replyTo: ConversationPartRef?)
    case edit(messageID: String, parts: [ConversationPart])
    case retract(messageID: String)
    case addReaction(messageID: String, partIndex: Int, kind: ConversationReactionKind)
    case removeReaction(messageID: String, partIndex: Int, kind: ConversationReactionKind)
    case setReadCursor(seq: UInt64)
    case addParticipant(ConversationParticipant)
    case setTitle(String)
    /// `question.answer`: `answer` is `{selections}` (CmuxAgentQuestion's `conversationAnswer`).
    case answerQuestion(messageID: String, partIndex: Int, answer: JSONValue)

    public var kindName: String {
        switch self {
        case .send: "message.send"
        case .edit: "message.edit"
        case .retract: "message.retract"
        case .addReaction: "reaction.add"
        case .removeReaction: "reaction.remove"
        case .setReadCursor: "read_cursor.set"
        case .addParticipant: "participants.add"
        case .setTitle: "title.set"
        case .answerQuestion: "question.answer"
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(kindName, forKey: DynamicKey("kind"))
        switch self {
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
            // The reaction's own `kind` object sits under `reaction`, since the op's tag is `kind`.
            try c.encode(messageID, forKey: DynamicKey("message_id"))
            try c.encode(partIndex, forKey: DynamicKey("part_index"))
            try c.encode(kind, forKey: DynamicKey("reaction"))
        case .setReadCursor(let seq):
            try c.encode(seq, forKey: DynamicKey("seq"))
        case .addParticipant(let participant):
            try c.encode(participant, forKey: DynamicKey("participant"))
        case .setTitle(let title):
            try c.encode(title, forKey: DynamicKey("title"))
        case .answerQuestion(let messageID, let partIndex, let answer):
            try c.encode(messageID, forKey: DynamicKey("message_id"))
            try c.encode(partIndex, forKey: DynamicKey("part_index"))
            try c.encode(answer, forKey: DynamicKey("answer"))
        }
    }
}

/// A coding key spelled exactly as given (the request encoder converts
/// camelCase keys to snake_case, which leaves these unchanged).
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
