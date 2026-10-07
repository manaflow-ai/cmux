/// `event` (cmux.wire/1): one committed op. Apply only when `seq` is the
/// mirror's seq + 1; a jump is a gap (send `snapshot.request`).
public struct EventFrame: Hashable, Sendable, Codable {
    public var stream: String
    public var seq: UInt64
    public var tx: String
    public var op: String
    public var params: JSONValue
    public var actor: [String: JSONValue]
    public var origin: Origin
    public var at: Int64
    /// Row-mode owners: the op's effects (new head state and row writes).
    public var effects: JSONValue?

    public init(stream: String, seq: UInt64, tx: String, op: String, params: JSONValue, actor: [String: JSONValue],
                origin: Origin, at: Int64, effects: JSONValue? = nil) {
        self.stream = stream
        self.seq = seq
        self.tx = tx
        self.op = op
        self.params = params
        self.actor = actor
        self.origin = origin
        self.at = at
        self.effects = effects
    }
}
