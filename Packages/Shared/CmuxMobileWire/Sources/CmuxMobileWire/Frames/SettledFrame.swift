/// `request-settled` (cmux.wire/1): always the last frame of a request.
public struct SettledFrame: Hashable, Sendable, Codable {
    public var tx: String
    public var idempotencyKey: String
    public var stream: String
    /// Seq of the request's last event, 0 when it caused none.
    public var sequence: UInt64
    public var ok: Bool

    public init(tx: String, idempotencyKey: String, stream: String, sequence: UInt64, ok: Bool) {
        self.tx = tx
        self.idempotencyKey = idempotencyKey
        self.stream = stream
        self.sequence = sequence
        self.ok = ok
    }

    enum CodingKeys: String, CodingKey {
        case tx, stream, sequence, ok
        case idempotencyKey = "idempotency_key"
    }
}
