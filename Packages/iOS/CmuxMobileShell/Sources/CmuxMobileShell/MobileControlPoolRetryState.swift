import Foundation

/// One retry budget shared by the complete control-connection pool.
///
/// A scheduled retry owns the next dial opportunity. Presence pushes and
/// simultaneous per-Mac failures must not create parallel timers or bypass its
/// cooldown.
struct MobileControlPoolRetryState: Sendable {
    private static let initialDelay: Duration = .seconds(2)
    private static let maximumDelay: Duration = .seconds(60)

    private var nextDelay = Self.initialDelay
    private(set) var isScheduled = false

    mutating func schedule() -> Duration? {
        guard !isScheduled else { return nil }
        isScheduled = true
        let delay = nextDelay
        nextDelay = min(delay * 2, Self.maximumDelay)
        return delay
    }

    mutating func fire() {
        isScheduled = false
    }

    /// Releases the scheduled slot without forgetting the grown delay.
    ///
    /// Backgrounding cancels the pending retry timer, but it is not evidence
    /// that an unreachable Mac became reachable. Keeping the delay means the
    /// next foreground's full aggregation pass still dials once (a foreground
    /// return is a legitimate retry moment) while a Mac that keeps failing
    /// does not restart the 2 s ladder every session.
    mutating func suspend() {
        isScheduled = false
    }

    mutating func reset() {
        isScheduled = false
        nextDelay = Self.initialDelay
    }
}
