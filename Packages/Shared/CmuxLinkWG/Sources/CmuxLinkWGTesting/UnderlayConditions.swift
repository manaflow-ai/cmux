/// Impairments of the in-memory underlay. Unlike a reliable stream, every
/// datagram is subject to them: this is what WireGuard over an unreliable
/// WebRTC data channel sees.
public struct UnderlayConditions: Sendable, Hashable {
    public var latency: Duration
    /// Extra one-way delay, uniform in `0...jitter`; reorders datagrams.
    public var jitter: Duration
    /// Probability in 0...1 that a datagram is lost.
    public var loss: Double
    /// Probability in 0...1 that a datagram is delivered twice.
    public var duplication: Double
    /// Serialization rate; `send` suspends for the datagram's transmit time.
    public var bytesPerSecond: Int?
    public var maxDatagramBytes: Int
    public var seed: UInt64

    public init(
        latency: Duration = .zero,
        jitter: Duration = .zero,
        loss: Double = 0,
        duplication: Double = 0,
        bytesPerSecond: Int? = nil,
        maxDatagramBytes: Int = 1200,
        seed: UInt64 = 0x5EED
    ) {
        self.latency = latency
        self.jitter = jitter
        self.loss = min(max(loss, 0), 1)
        self.duplication = min(max(duplication, 0), 1)
        self.bytesPerSecond = bytesPerSecond
        self.maxDatagramBytes = maxDatagramBytes
        self.seed = seed
    }

    public static let perfect = UnderlayConditions()
}
