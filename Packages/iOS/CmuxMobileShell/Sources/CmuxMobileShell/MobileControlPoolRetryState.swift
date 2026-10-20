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

    mutating func reset() {
        isScheduled = false
        nextDelay = Self.initialDelay
    }
}
