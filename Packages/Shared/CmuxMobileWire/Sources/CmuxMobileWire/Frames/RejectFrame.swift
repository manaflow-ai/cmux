/// `reject` (cmux.wire/1): an op's refusal, in the shared error shape.
public struct RejectFrame: Hashable, Sendable, Codable {
    public var tx: String
    public var idempotencyKey: String
    public var code: String
    public var message: String
    public var details: JSONValue?
    public var retryable: Bool
    public var replayed: Bool

    public init(tx: String, idempotencyKey: String, code: String, message: String, details: JSONValue? = nil,
                retryable: Bool, replayed: Bool) {
        self.tx = tx
        self.idempotencyKey = idempotencyKey
        self.code = code
        self.message = message
        self.details = details
        self.retryable = retryable
        self.replayed = replayed
    }

    enum CodingKeys: String, CodingKey {
        case tx, code, message, details, retryable, replayed
        case idempotencyKey = "idempotency_key"
    }
}
