import Foundation

struct SimulatorFramebufferPublicationFailurePolicy: Sendable {
    let maximumConsecutiveFailureCount: Int
    let initialRetryDelay: Duration
    private var consecutiveFailureCount = 0

    init(
        maximumConsecutiveFailureCount: Int = 3,
        initialRetryDelay: Duration = .milliseconds(50)
    ) {
        self.maximumConsecutiveFailureCount = max(1, maximumConsecutiveFailureCount)
        self.initialRetryDelay = initialRetryDelay
    }

    mutating func retryDelayAfterFailure() -> Duration? {
        consecutiveFailureCount += 1
        guard consecutiveFailureCount < maximumConsecutiveFailureCount else { return nil }
        var delay = initialRetryDelay
        if consecutiveFailureCount > 1 {
            for _ in 1..<consecutiveFailureCount {
                delay += delay
            }
        }
        return delay
    }

    mutating func recordSuccess() {
        consecutiveFailureCount = 0
    }
}
