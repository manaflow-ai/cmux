/// Messages were lost beyond what the sender retained. The feature resyncs
/// from a snapshot through its own RPC, then keeps consuming.
public struct ChannelGap: Sendable, Hashable {
    /// The last revision this side took before the gap.
    public var lastDelivered: StreamCursor
    /// Delivery continues after this revision.
    public var resumedAfter: StreamCursor
    public var reason: GapReason

    public init(lastDelivered: StreamCursor, resumedAfter: StreamCursor, reason: GapReason) {
        self.lastDelivered = lastDelivered
        self.resumedAfter = resumedAfter
        self.reason = reason
    }
}
