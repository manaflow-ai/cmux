/// `snapshot.request` (cmux.wire/1): the client saw a gap and asks for a snapshot.
public struct SnapshotRequestFrame: Hashable, Sendable, Codable {
    public var stream: String?
    public var pending: [String]?

    public init(stream: String? = nil, pending: [String]? = nil) {
        self.stream = stream
        self.pending = pending
    }
}
