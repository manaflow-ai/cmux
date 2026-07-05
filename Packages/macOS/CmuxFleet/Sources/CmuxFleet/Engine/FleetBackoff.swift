/// Computes deterministic Fleet retry backoff delays.
public struct FleetBackoff: Sendable {
    /// The maximum delay in milliseconds.
    public var maxMS: Int

    /// Creates a retry backoff policy.
    /// - Parameter maxMS: The maximum delay in milliseconds.
    public init(maxMS: Int = 300_000) {
        self.maxMS = maxMS
    }

    /// Returns the exponential retry delay for a one-based attempt.
    /// - Parameter attempt: The one-based attempt number; values below one are treated as one.
    /// - Returns: `min(10_000 * 2^(attempt - 1), maxMS)`, without integer overflow.
    public func delayMS(attempt: Int) -> Int {
        let limit = max(0, maxMS)
        guard limit > 0 else {
            return 0
        }

        var delay = 10_000
        let clampedAttempt = max(1, attempt)
        var remainingDoublings = clampedAttempt - 1
        var performedDoublings = 0

        while remainingDoublings > 0 {
            if delay >= limit {
                return limit
            }

            let multiplied = delay.multipliedReportingOverflow(by: 2)
            if multiplied.overflow {
                return limit
            }

            delay = multiplied.partialValue
            remainingDoublings -= 1
            performedDoublings += 1

            if performedDoublings >= Int.bitWidth {
                return limit
            }
        }

        return min(delay, limit)
    }
}
