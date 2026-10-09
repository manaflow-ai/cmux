/// The payload of a credit record.
public struct CreditGrant: Hashable, Sendable {
    /// Highest contiguous seq the receiver applied.
    public var ackSeq: UInt64
    /// Additional payload bytes the sender may have unacknowledged.
    public var grantBytes: UInt32

    public init(ackSeq: UInt64, grantBytes: UInt32) {
        self.ackSeq = ackSeq
        self.grantBytes = grantBytes
    }
}
