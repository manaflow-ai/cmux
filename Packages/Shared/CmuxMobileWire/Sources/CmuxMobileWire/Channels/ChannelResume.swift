/// Resume point of a reopened channel: the last contiguous seq the client applied.
public struct ChannelResume: Hashable, Sendable, Codable {
    public var recvSeq: UInt64

    public init(recvSeq: UInt64) {
        self.recvSeq = recvSeq
    }

    enum CodingKeys: String, CodingKey {
        case recvSeq = "recv_seq"
    }
}
