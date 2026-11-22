import Foundation

/// A tapback or an emoji reaction.
public enum ConversationReactionKind: Codable, Sendable, Hashable {
    case tapback(String)
    case emoji(String)

    enum CodingKeys: String, CodingKey { case tapback, emoji }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let tapback = try container.decodeIfPresent(String.self, forKey: .tapback) {
            self = .tapback(tapback)
        } else {
            self = .emoji(try container.decode(String.self, forKey: .emoji))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tapback(let value): try container.encode(value, forKey: .tapback)
        case .emoji(let value): try container.encode(value, forKey: .emoji)
        }
    }
}

/// One reaction record; add and remove are separate ops, so concurrent
/// tapbacks never overwrite each other.
public struct ConversationReaction: Codable, Sendable, Hashable {
    public var author: String
    public var partIndex: Int
    public var kind: ConversationReactionKind
    public var at: String

    enum CodingKeys: String, CodingKey {
        case author, kind, at
        case partIndex = "part_index"
    }
}

/// A committed message. `seq` is dense per conversation, starting at 1.
public struct ConversationMessage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var conversation: String
    public var seq: UInt64
    public var clientMsgID: String
    public var author: String
    public var parts: [ConversationPart]
    public var replyTo: ConversationPartRef?
    /// RFC 3339 UTC with milliseconds.
    public var createdAt: String
    public var editedAt: String?
    public var retractedAt: String?
    public var reactions: [ConversationReaction]

    public init(id: String, conversation: String, seq: UInt64, clientMsgID: String, author: String, parts: [ConversationPart],
                replyTo: ConversationPartRef? = nil, createdAt: String, editedAt: String? = nil, retractedAt: String? = nil,
                reactions: [ConversationReaction] = []) {
        self.id = id
        self.conversation = conversation
        self.seq = seq
        self.clientMsgID = clientMsgID
        self.author = author
        self.parts = parts
        self.replyTo = replyTo
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.retractedAt = retractedAt
        self.reactions = reactions
    }

    enum CodingKeys: String, CodingKey {
        case id, conversation, seq, author, parts, reactions
        case clientMsgID = "client_msg_id"
        case replyTo = "reply_to"
        case createdAt = "created_at"
        case editedAt = "edited_at"
        case retractedAt = "retracted_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversation = try c.decode(String.self, forKey: .conversation)
        seq = try c.decode(UInt64.self, forKey: .seq)
        clientMsgID = try c.decode(String.self, forKey: .clientMsgID)
        author = try c.decode(String.self, forKey: .author)
        parts = try c.decode([ConversationPart].self, forKey: .parts)
        replyTo = try c.decodeIfPresent(ConversationPartRef.self, forKey: .replyTo)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        editedAt = try c.decodeIfPresent(String.self, forKey: .editedAt)
        retractedAt = try c.decodeIfPresent(String.self, forKey: .retractedAt)
        reactions = try c.decodeIfPresent([ConversationReaction].self, forKey: .reactions) ?? []
    }
}
