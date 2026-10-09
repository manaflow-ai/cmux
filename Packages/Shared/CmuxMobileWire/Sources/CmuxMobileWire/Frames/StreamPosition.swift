/// A stream and the last seq applied from it (resume after reconnect).
public struct StreamPosition: Hashable, Sendable, Codable {
    public var stream: String
    public var seq: UInt64

    public init(stream: String, seq: UInt64) {
        self.stream = stream
        self.seq = seq
    }
}
