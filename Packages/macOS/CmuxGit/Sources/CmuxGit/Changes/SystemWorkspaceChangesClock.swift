import Foundation

/// Production monotonic clock for summary-cache expiration.
struct SystemWorkspaceChangesClock: WorkspaceChangesClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    init() {
        origin = clock.now
    }

    func now() async -> Duration {
        origin.duration(to: clock.now)
    }
}
