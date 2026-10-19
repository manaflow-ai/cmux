/// Decides which main-thread lag spikes are sent, so a bad minute (a stall
/// every frame) costs a few events, not thousands.
///
/// A token bucket: ``capacity`` reports at once, then one more every
/// ``refillNanos``. Spikes shorter than ``minimumNanos`` are never sent.
/// A pure value: the caller holds it under its own lock and passes the
/// clock in, so tests drive it with plain numbers.
public nonisolated struct LagSpikeRateLimiter: Sendable, Equatable {
    /// The shortest spike that is sent (default 250 ms).
    public let minimumNanos: UInt64
    /// Reports allowed in one burst (default 10).
    public let capacity: Int
    /// One token comes back this often (default 2 min: at most ~30 an hour
    /// after the first burst).
    public let refillNanos: UInt64
    private var tokens: Int
    private var lastRefillNanos: UInt64?

    public init(minimumNanos: UInt64 = 250_000_000, capacity: Int = 10, refillNanos: UInt64 = 120_000_000_000) {
        self.minimumNanos = minimumNanos
        self.capacity = max(1, capacity)
        self.refillNanos = max(1, refillNanos)
        self.tokens = max(1, capacity)
    }

    /// Whether a spike of `durationNanos` that ended at `nowNanos` (a
    /// monotonic clock) is sent; takes a token when it is.
    public mutating func admit(durationNanos: UInt64, nowNanos: UInt64) -> Bool {
        guard durationNanos >= minimumNanos else { return false }
        if let last = lastRefillNanos {
            if nowNanos > last {
                let earned = (nowNanos - last) / refillNanos
                if earned > 0 {
                    tokens = min(capacity, tokens + Int(clamping: earned))
                    lastRefillNanos = last &+ earned &* refillNanos
                }
            }
        } else {
            lastRefillNanos = nowNanos
        }
        guard tokens > 0 else { return false }
        tokens -= 1
        return true
    }
}
