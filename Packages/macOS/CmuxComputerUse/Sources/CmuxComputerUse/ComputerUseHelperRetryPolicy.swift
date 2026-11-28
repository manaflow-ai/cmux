import Foundation

/// Caps repeated helper failures without delaying or sleeping in an operation.
struct ComputerUseHelperRetryPolicy: Sendable {
    private(set) var nextAttemptUptime: TimeInterval = 0
    private var delay: TimeInterval = 5

    /// Whether the caller may start work at the supplied monotonic uptime.
    func allowsAttempt(at uptime: TimeInterval) -> Bool {
        uptime >= nextAttemptUptime
    }

    /// Backs off 5, 10, 20, 40, 80, 160, then at most 300 seconds.
    mutating func recordFailure(at uptime: TimeInterval) {
        nextAttemptUptime = uptime + delay
        delay = min(delay * 2, 300)
    }

    /// Resets after success or a deliberate disable/enable transition.
    mutating func reset() {
        self = Self()
    }
}
