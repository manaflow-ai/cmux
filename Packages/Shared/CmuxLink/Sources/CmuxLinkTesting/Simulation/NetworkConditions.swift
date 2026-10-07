/// Impairments a simulated path applies (a3-link.md section 9).
public struct NetworkConditions: Sendable, Hashable {
    /// One-way base latency.
    public var latency: Duration
    /// Extra one-way delay, uniform in `0...jitter`. Reorders lanes that are
    /// not reliable-ordered.
    public var jitter: Duration
    /// Probability in 0...1 that a frame on a non-reliable lane is lost. On
    /// reliable lanes it costs a retransmission delay instead.
    public var loss: Double
    /// Serialization rate; `send` suspends for the frame's transmit time.
    public var bytesPerSecond: Int?
    public var seed: UInt64

    public init(
        latency: Duration = .zero,
        jitter: Duration = .zero,
        loss: Double = 0,
        bytesPerSecond: Int? = nil,
        seed: UInt64 = 0x5EED
    ) {
        self.latency = latency
        self.jitter = jitter
        self.loss = min(max(loss, 0), 1)
        self.bytesPerSecond = bytesPerSecond
        self.seed = seed
    }

    public static let perfect = NetworkConditions()
}
