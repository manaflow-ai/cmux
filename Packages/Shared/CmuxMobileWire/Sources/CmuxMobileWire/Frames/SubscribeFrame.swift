/// `subscribe` (cmux.wire/1): start or resume a stream. With `afterSeq` and no
/// pending intents the owner replays the gap; otherwise it sends a snapshot
/// carrying the decided keys of `pending`.
public struct SubscribeFrame: Hashable, Sendable, Codable {
    public var stream: String?
    public var afterSeq: UInt64?
    public var pending: [String]?

    public init(stream: String? = nil, afterSeq: UInt64? = nil, pending: [String]? = nil) {
        self.stream = stream
        self.afterSeq = afterSeq
        self.pending = pending
    }

    enum CodingKeys: String, CodingKey {
        case stream, pending
        case afterSeq = "after_seq"
    }
}
