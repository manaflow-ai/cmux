import Foundation

// `local-conversations-v1` writes. Every write carries an idempotency key
// chosen by the client; the owner applies it once.

/// `conversation-create`: idempotent by `idempotencyKey`.
public struct CreateConversationRequest: DaemonRequest {
    public typealias Response = ConversationCreated
    public static let command = "conversation-create"
    public var idempotencyKey: String
    /// Omitted: the owner stamps the connection's principal.
    public var actor: String?
    public var title: String
    public var participants: [ConversationParticipant]
    public init(idempotencyKey: String, actor: String? = nil, title: String, participants: [ConversationParticipant]) {
        self.idempotencyKey = idempotencyKey
        self.actor = actor
        self.title = title
        self.participants = participants
    }
    enum CodingKeys: String, CodingKey {
        case actor, title, participants
        case idempotencyKey = "idempotency_key"
    }
}

/// `conversation-op`: one typed op; the reply and the event carry `transaction`.
public struct ConversationOpRequest: DaemonRequest {
    public typealias Response = ConversationOpResult
    public static let command = "conversation-op"
    public var conversation: String
    public var idempotencyKey: String
    /// Omitted: the owner stamps the connection's principal.
    public var actor: String?
    public var transaction: ClientTransactionID?
    public var op: ConversationOp
    public init(conversation: String, idempotencyKey: String, actor: String? = nil, transaction: ClientTransactionID?,
                op: ConversationOp) {
        self.conversation = conversation
        self.idempotencyKey = idempotencyKey
        self.actor = actor
        self.transaction = transaction
        self.op = op
    }
    enum CodingKeys: String, CodingKey {
        case conversation, actor, transaction, op
        case idempotencyKey = "idempotency_key"
    }
}

/// `conversation-typing`: ephemeral, never stored.
public struct ConversationTypingRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "conversation-typing"
    public var conversation: String
    public var actor: String?
    public var on: Bool
    public init(conversation: String, actor: String? = nil, on: Bool) {
        self.conversation = conversation
        self.actor = actor
        self.on = on
    }
}
