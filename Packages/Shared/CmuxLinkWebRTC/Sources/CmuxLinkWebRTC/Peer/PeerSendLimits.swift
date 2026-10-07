/// How a peer paces lane messages into libwebrtc (b2-webrtc.md section 6).
struct PeerSendLimits: Sendable {
    /// Largest data channel message (header included).
    var maxMessageBytes: Int
    /// A channel takes another message only while its `bufferedAmount` is at
    /// or below this, so the SCTP send buffer never bursts past it.
    var channelHighWater: UInt64
    /// Datagram mode: `send` resumes once the buffer falls to this.
    var lowWater: UInt64
    /// Bytes a lane may queue in the carrier before `send` suspends
    /// (reliable) or drops (unordered, partial).
    var laneBudget: Int
    /// Reliable lane bytes sent but not yet credited by the peer. Bounds
    /// what SCTP can burst into the receiver's UDP socket.
    var inFlightWindow: Int
    /// The receiver credits after this many new bytes.
    var creditEvery: Int

    init(_ configuration: WebRTCConfiguration) {
        maxMessageBytes = configuration.maxMessageBytes
        channelHighWater = configuration.highWaterBytes
        lowWater = configuration.lowWaterBytes
        laneBudget = configuration.laneBudgetBytes
        inFlightWindow = configuration.inFlightWindowBytes
        creditEvery = max(configuration.inFlightWindowBytes / 8, 4096)
    }
}
