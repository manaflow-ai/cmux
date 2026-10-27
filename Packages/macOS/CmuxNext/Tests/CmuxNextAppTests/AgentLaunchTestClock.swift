import Foundation

/// Advances retry delays immediately while preserving task cancellation in launch tests.
nonisolated struct AgentLaunchTestClock: Clock {
    var now: ContinuousClock.Instant { ContinuousClock.now }
    var minimumResolution: Duration { .nanoseconds(1) }
    func sleep(until _: ContinuousClock.Instant, tolerance _: Duration?) async throws {
        try Task.checkCancellation()
    }
}
