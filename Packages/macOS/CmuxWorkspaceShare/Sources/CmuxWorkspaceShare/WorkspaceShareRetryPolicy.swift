/// Classifies connection failures and calculates bounded retry delays.
public struct WorkspaceShareRetryPolicy: Equatable, Sendable {
    /// A retry decision for one failed connection attempt.
    public enum Decision: Equatable, Sendable {
        /// Retry after the associated bounded delay.
        case retry(after: Duration)

        /// Stop reconnecting because the failure is permanent.
        case stop
    }

    /// Creates the default exponential-backoff policy.
    public init() {}

    /// Classifies a failure and returns its retry delay.
    ///
    /// Backoff starts at 500 milliseconds, doubles per failed attempt, caps at
    /// 30 seconds, and adds up to 25 percent deterministic jitter.
    ///
    /// - Parameters:
    ///   - failure: Failure reported by the connection lifecycle.
    ///   - attempt: Zero-based failed attempt number.
    ///   - randomUnitInterval: Injected random value, clamped to `0...1`.
    /// - Returns: A retry delay or a permanent stop decision.
    public func decision(
        for failure: WorkspaceShareSessionLifecycle.Failure,
        attempt: Int,
        randomUnitInterval: Double
    ) -> Decision {
        guard isRetryable(failure) else { return .stop }

        let clampedAttempt = min(max(0, attempt), 6)
        let exponentialNanoseconds = 500_000_000 * (Int64(1) << clampedAttempt)
        let baseNanoseconds = min(Int64(30_000_000_000), exponentialNanoseconds)
        let random = min(max(randomUnitInterval, 0), 1)
        let jitterNanoseconds = Int64(
            (Double(baseNanoseconds) * 0.25 * random).rounded()
        )
        var delay = Duration.nanoseconds(baseNanoseconds + jitterNanoseconds)

        if case .http(_, let retryAfter?) = failure, retryAfter > delay {
            delay = retryAfter
        }
        return .retry(after: delay)
    }

    private func isRetryable(_ failure: WorkspaceShareSessionLifecycle.Failure) -> Bool {
        switch failure {
        case .transport:
            return true
        case .http(let statusCode, _):
            return statusCode == 408
                || statusCode == 425
                || statusCode == 429
                || (500...599).contains(statusCode)
        case .webSocketClosed(let code, let reason):
            if code == 1002
                || code == 1008
                || code == 1009
                || code == 4400 {
                return false
            }
            if code == 1011,
               (reason == "delivery_failed"
                    || reason == "server_message_too_large") {
                return false
            }
            return code == 1001
                || code == 1005
                || code == 1006
                || code == 4008
                || code == 4429
                || (1011...1015).contains(code)
        case .invalidEndpoint, .cancelled:
            return false
        }
    }
}
