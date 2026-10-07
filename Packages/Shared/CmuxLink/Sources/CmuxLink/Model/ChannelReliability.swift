/// Delivery promise of one channel (a3-link.md section 4).
public enum ChannelReliability: Sendable, Hashable {
    /// Exactly once, in order, across transport loss while the sender
    /// retained the message. Credit-based back-pressure.
    case reliableOrdered
    /// Delivered as it arrives, may be lost or reordered. A full send queue
    /// drops its oldest message. Not resumed.
    case unreliableUnordered
    /// Newest wins: delivered in revision order, older arrivals dropped; the
    /// sender drops queued messages older than `maxLifetime`. Not resumed.
    case partial(maxLifetime: Duration)

    public var isReliable: Bool { self == .reliableOrdered }
}
