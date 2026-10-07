/// An idempotency key the owner has decided, so a pending intent settles from a snapshot.
public struct DecidedKey: Hashable, Sendable, Codable {
    public var idempotencyKey: String
    public var ok: Bool
    public var sequence: UInt64

    public init(idempotencyKey: String, ok: Bool, sequence: UInt64) {
        self.idempotencyKey = idempotencyKey
        self.ok = ok
        self.sequence = sequence
    }

    enum CodingKeys: String, CodingKey {
        case ok, sequence
        case idempotencyKey = "idempotency_key"
    }
}
