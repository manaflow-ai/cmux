import Foundation

/// An injected monotonic clock shared by a read's deadline and Retry-After gate.
struct CloudRequestClock: Sendable {
    let now: @Sendable () -> Duration
    let sleepUntil: @Sendable (Duration) async throws -> Void

    init<C: Clock<Duration>>(_ clock: C) {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleepUntil = { try await clock.sleep(until: origin.advanced(by: $0), tolerance: nil) }
    }
}
