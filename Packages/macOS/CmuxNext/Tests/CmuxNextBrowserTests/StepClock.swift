import Foundation

/// A clock whose sleeps end at once, after telling the test each step
/// (`onSleep` runs on the main actor with the step's duration).
struct StepClock: Clock {
    typealias Instant = ContinuousClock.Instant
    var onSleep: @MainActor (Duration) -> Void
    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        await onSleep(ContinuousClock.now.duration(to: deadline))
    }
}
