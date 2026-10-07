/// Delay before reconnect attempt `n` after a failure (exponential, capped,
/// deterministic). Nothing retries on a fixed timer.
public struct Backoff: Sendable, Hashable {
    public var initial: Duration
    public var maximum: Duration
    public var multiplier: Int

    public init(initial: Duration = .milliseconds(100), maximum: Duration = .seconds(5), multiplier: Int = 2) {
        self.initial = initial
        self.maximum = maximum
        self.multiplier = max(1, multiplier)
    }

    /// `attempt` is 1-based: the delay before the second try is `delay(after: 1)`.
    public func delay(after attempt: Int) -> Duration {
        var delay = initial
        var step = 1
        while step < attempt, delay < maximum {
            delay *= multiplier
            step += 1
        }
        return min(delay, maximum)
    }
}
