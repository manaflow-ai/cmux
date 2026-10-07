/// `snapshot` (cmux.wire/1): the stream's state at `seq` plus the requester's decided keys.
public struct SnapshotFrame: Hashable, Sendable, Codable {
    public var stream: String
    public var seq: UInt64
    public var state: JSONValue
    public var decided: [DecidedKey]
    public var rows: JSONValue?

    public init(stream: String, seq: UInt64, state: JSONValue, decided: [DecidedKey], rows: JSONValue? = nil) {
        self.stream = stream
        self.seq = seq
        self.state = state
        self.decided = decided
        self.rows = rows
    }
}
