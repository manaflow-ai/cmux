import Foundation

/// Clock seam used to make minimap auto-hide timing cancellable and testable.
struct CanvasMinimapAutoHideClock: Sendable {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    init<C: Clock & Sendable>(_ clock: C) where C.Duration == Duration {
        let start = clock.now
        now = { start.duration(to: clock.now) }
        sleep = { @Sendable duration in try await clock.sleep(for: duration) }
    }
}
