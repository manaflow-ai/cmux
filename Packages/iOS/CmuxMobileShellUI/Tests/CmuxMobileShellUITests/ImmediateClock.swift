#if canImport(UIKit)
import Foundation

struct ImmediateClock: Clock {
    typealias Duration = Swift.Duration
    typealias Instant = ContinuousClock.Instant

    var now: Instant { .now }
    var minimumResolution: Duration { .zero }

    func sleep(until _: Instant, tolerance _: Duration? = nil) async throws {}
}
#endif
