import Foundation

/// What one committed op changed.
public enum ConversationChange: Decodable, Sendable, Hashable {
    case message(ConversationMessage)
    case messageUpdated(ConversationMessage)
    case readCursor(participant: String, seq: UInt64)
    case conversation(ConversationSummary)
    case unknown(kind: String)

    enum CodingKeys: String, CodingKey { case kind, message, participant, seq, conversation }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "message": self = .message(try c.decode(ConversationMessage.self, forKey: .message))
        case "message-updated": self = .messageUpdated(try c.decode(ConversationMessage.self, forKey: .message))
        case "read-cursor":
            self = .readCursor(participant: try c.decode(String.self, forKey: .participant), seq: try c.decode(UInt64.self, forKey: .seq))
        case "conversation": self = .conversation(try c.decode(ConversationSummary.self, forKey: .conversation))
        default: self = .unknown(kind: kind)
        }
    }
}

/// A `conversation-changed` event: one committed op, in `rev` order.
public struct ConversationEvent: Decodable, Sendable, Hashable {
    public var conversation: String
    public var rev: UInt64
    public var transaction: ClientTransactionID?
    public var change: ConversationChange

    public init(conversation: String, rev: UInt64, transaction: ClientTransactionID?, change: ConversationChange) {
        self.conversation = conversation
        self.rev = rev
        self.transaction = transaction
        self.change = change
    }
}

/// A `conversation-typing` event (ephemeral).
public struct ConversationTyping: Decodable, Sendable, Hashable {
    public var conversation: String
    public var participant: String
    public var on: Bool

    public init(conversation: String, participant: String, on: Bool) {
        self.conversation = conversation
        self.participant = participant
        self.on = on
    }
}

/// A `conversation-draft` event (`conversation-draft-events-v1`, ephemeral):
/// the running reply of an agent participant, never stored. `fresh` text
/// replaces the turn's draft, other text appends to it; `done` ends it.
public struct ConversationDraft: Decodable, Sendable, Hashable {
    public struct Item: Decodable, Sendable, Hashable {
        public var turn: String
        public var segment: UInt64
        public var seq: UInt64
        public var kind: String
        public var text: String
        public var fresh: Bool
        public var done: Bool

        public init(turn: String, segment: UInt64, seq: UInt64, kind: String, text: String, fresh: Bool, done: Bool) {
            self.turn = turn
            self.segment = segment
            self.seq = seq
            self.kind = kind
            self.text = text
            self.fresh = fresh
            self.done = done
        }
    }

    public var conversation: String
    public var participant: String
    public var item: Item

    public init(conversation: String, participant: String, item: Item) {
        self.conversation = conversation
        self.participant = participant
        self.item = item
    }
}
