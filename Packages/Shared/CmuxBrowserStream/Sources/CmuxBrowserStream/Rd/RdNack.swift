/// A request to resend missing shards of one frame.
public struct RdNack: Hashable, Sendable {
    public var frame: UInt32
    public var indexes: [UInt16]

    public init(frame: UInt32, indexes: [UInt16]) {
        self.frame = frame
        self.indexes = indexes
    }
}
