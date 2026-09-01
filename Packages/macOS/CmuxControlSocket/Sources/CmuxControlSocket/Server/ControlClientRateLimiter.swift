public import Dispatch

/// A per-connection token-bucket limiter for control-plane polling commands.
///
/// The limiter never sleeps and never waits for the main actor. It either
/// admits a request or returns a retry hint, allowing the connection task to
/// apply backpressure to only the hot client while unrelated clients continue
/// through the pool. Mutating commands and one-shot probes are always allowed.
public actor ControlClientRateLimiter {
    /// Token-bucket tuning values.
    public struct Configuration: Sendable, Equatable {
        /// Number of polling requests admitted immediately for a new client.
        public let burst: Int
        /// Nanoseconds required to refill one token.
        public let refillIntervalNanoseconds: UInt64

        /// Creates a limiter configuration.
        ///
        /// Values are clamped to a positive burst and a non-zero interval so
        /// the limiter cannot accidentally become an unbounded admission path.
        public init(
            burst: Int = 4,
            refillIntervalNanoseconds: UInt64 = 100_000_000
        ) {
            self.burst = max(1, burst)
            self.refillIntervalNanoseconds = max(1, refillIntervalNanoseconds)
        }
    }

    /// The admission outcome for one command.
    public enum Decision: Sendable, Equatable {
        /// The command may execute now.
        case allowed
        /// The command should be retried after the supplied number of
        /// milliseconds. The value is always at least one.
        case limited(retryAfterMilliseconds: Int)
    }

    private let configuration: Configuration
    private let now: @Sendable () -> UInt64
    private var tokens: Int
    private var lastRefillNanoseconds: UInt64

    /// Creates a limiter for one client connection.
    ///
    /// - Parameters:
    ///   - configuration: Token-bucket limits.
    ///   - now: Monotonic clock used for refill calculations. Tests inject a
    ///     deterministic clock; production uses `DispatchTime`.
    public init(
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.configuration = configuration
        self.now = now
        self.tokens = configuration.burst
        self.lastRefillNanoseconds = now()
    }

    /// Admits a command or returns a retry hint for a hot polling client.
    ///
    /// - Parameter method: The normalized v1 command or v2 method name.
    /// - Returns: The admission decision.
    public func admit(method: String) -> Decision {
        guard ControlCommandExecutionPolicy.pollingMethods.contains(method) else { return .allowed }
        refill()
        guard tokens > 0 else {
            let current = now()
            let elapsed = current >= lastRefillNanoseconds
                ? current - lastRefillNanoseconds
                : 0
            let remainder = elapsed % configuration.refillIntervalNanoseconds
            let remaining = configuration.refillIntervalNanoseconds - remainder
            let rounded = remaining > UInt64.max - 999_999
                ? UInt64.max
                : remaining + 999_999
            let milliseconds = max(1, Int(clamping: rounded / 1_000_000))
            return .limited(retryAfterMilliseconds: milliseconds)
        }
        tokens -= 1
        return .allowed
    }

    /// Restores a full burst for a newly authenticated/reused connection.
    public func reset() {
        tokens = configuration.burst
        lastRefillNanoseconds = now()
    }

    private func refill() {
        let current = now()
        let elapsed = current >= lastRefillNanoseconds
            ? current - lastRefillNanoseconds
            : 0
        guard elapsed >= configuration.refillIntervalNanoseconds else { return }
        let additions = Int(elapsed / configuration.refillIntervalNanoseconds)
        tokens = min(configuration.burst, tokens + additions)
        lastRefillNanoseconds = current
    }
}
