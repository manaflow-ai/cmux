import Foundation

// `local-conversations-v1` writes. Every write carries an idempotency key
// chosen by the client; the owner applies it once.

/// `conversation-op`: one typed op; the reply and the event carry `transaction`.
public struct ConversationOpRequest: DaemonRequest {
    public typealias Response = ConversationOpResult
    public static let command = "conversation-op"
    public static let requiredCapability: String? = DaemonCapability.localConversations.rawValue
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
