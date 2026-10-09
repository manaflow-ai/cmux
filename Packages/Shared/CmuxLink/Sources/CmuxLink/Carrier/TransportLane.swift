/// A carrier-level lane: the delivery class and priority a frame needs. A
/// WebRTC carrier maps each distinct lane to one data channel; a direct
/// carrier maps reliable lanes to a stream and the rest to datagrams.
public struct TransportLane: Sendable, Hashable {
    public var reliability: ChannelReliability
    public var priority: ChannelPriority

    public init(reliability: ChannelReliability, priority: ChannelPriority) {
        self.reliability = reliability
        self.priority = priority
    }

    /// Session control frames (hello, welcome, acks, session close).
    public static let control = TransportLane(reliability: .reliableOrdered, priority: .input)
}
