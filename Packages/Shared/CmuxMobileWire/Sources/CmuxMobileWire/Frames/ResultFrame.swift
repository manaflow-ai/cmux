/// `result` (cmux.wire/1): an op's value; `replayed` when the key was already decided.
public struct ResultFrame: Hashable, Sendable, Codable {
    public var tx: String
    public var idempotencyKey: String
    public var value: JSONValue
    public var revision: String
    public var replayed: Bool

    public init(tx: String, idempotencyKey: String, value: JSONValue, revision: String, replayed: Bool) {
        self.tx = tx
        self.idempotencyKey = idempotencyKey
        self.value = value
        self.revision = revision
        self.replayed = replayed
    }

    enum CodingKeys: String, CodingKey {
        case tx, value, revision, replayed
        case idempotencyKey = "idempotency_key"
    }
}
