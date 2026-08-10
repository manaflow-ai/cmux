import Foundation

struct MobileBrowserContinuousClock: MobileBrowserStreamClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    init() {
        origin = clock.now
    }

    var now: TimeInterval {
        let components = origin.duration(to: clock.now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else { return }
        try await clock.sleep(for: .seconds(interval))
    }
}
