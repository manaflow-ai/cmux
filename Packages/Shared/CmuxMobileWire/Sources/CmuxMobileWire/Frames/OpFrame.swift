/// `op` (cmux.wire/1): one typed mutation with a client-chosen idempotency key.
public struct OpFrame: Hashable, Sendable, Codable {
    public var op: String
    public var params: JSONValue
    public var idempotencyKey: String
    public var origin: Origin?
    public var expectedRevision: String?
    public var stream: String?

    public init(op: String, params: JSONValue, idempotencyKey: String, origin: Origin? = nil,
                expectedRevision: String? = nil, stream: String? = nil) {
        self.op = op
        self.params = params
        self.idempotencyKey = idempotencyKey
        self.origin = origin
        self.expectedRevision = expectedRevision
        self.stream = stream
    }

    enum CodingKeys: String, CodingKey {
        case op, params, origin, stream
        case idempotencyKey = "idempotency_key"
        case expectedRevision = "expected_revision"
    }
}
