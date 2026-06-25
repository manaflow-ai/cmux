public import Foundation

/// Tracks in-flight mobile request/connection activity so the host's idle-quiet
/// logic can decide when the listener has been silent long enough to act on.
///
/// Three counters/timestamps under one lock: how many requests are being served
/// (`activeRequestCount`), how many connections are open (`activeConnectionCount`),
/// and the monotonic uptime of the last request boundary (`lastActivityUptime`).
/// `hasRecentActivity(within:)` and `quietDelay(for:)` answer "has the host been
/// busy in the last N seconds" and "how long until the quiet window elapses" from
/// those values.
///
/// This is a constructor-injected instance, not a static namespace:
/// `MobileHostService` owns one shared default and forwards its idle/quiet and
/// begin/end calls into it, replacing the previous lock-guarded static-state
/// `MobileHostRequestActivity` namespace. The clock is injected as
/// `() -> TimeInterval` (production passes `ProcessInfo.processInfo.systemUptime`)
/// so the quiet-window math is unit-testable without a real monotonic clock.
///
/// The instance state is guarded by an `NSLock` because the readers/writers run
/// across arbitrary actors and queues (connection actors, the request-serving
/// path, and synchronous idle-quiet readers), so `@unchecked Sendable` is
/// justified by that single lock owning every access to the three fields plus the
/// `Sendable` clock closure.
public final class MobileHostRequestActivityTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let uptime: @Sendable () -> TimeInterval
    private var activeRequestCount = 0
    private var activeConnectionCount = 0
    private var lastActivityUptime: TimeInterval = 0

    /// - Parameter uptime: Monotonic seconds source. Defaults to
    ///   `ProcessInfo.processInfo.systemUptime`; tests inject a controllable clock.
    public init(uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    /// True while any request is being served.
    public var hasActiveRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeRequestCount > 0
    }

    /// True if a request is in flight, or the last request boundary was less than
    /// `interval` seconds ago.
    public func hasRecentActivity(within interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeRequestCount == 0 else { return true }
        guard lastActivityUptime > 0 else { return false }
        return uptime() - lastActivityUptime < interval
    }

    /// Seconds remaining before the host has been quiet for `interval`. Returns
    /// the full `interval` while a request is in flight, and `0` once the window
    /// has already elapsed (or no activity has been recorded).
    public func quietDelay(for interval: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard activeRequestCount == 0 else { return interval }
        guard lastActivityUptime > 0 else { return 0 }
        let elapsed = uptime() - lastActivityUptime
        return max(0, interval - elapsed)
    }

    /// Records a newly accepted connection.
    public func beginConnection() {
        lock.lock()
        activeConnectionCount += 1
        lock.unlock()
    }

    /// Records a closed connection.
    public func endConnection() {
        lock.lock()
        activeConnectionCount = max(0, activeConnectionCount - 1)
        lock.unlock()
    }

    /// Marks the start of a served request and stamps the activity time.
    public func beginRequest() {
        lock.lock()
        lastActivityUptime = uptime()
        activeRequestCount += 1
        lock.unlock()
    }

    /// Marks the end of a served request and stamps the activity time.
    public func endRequest() {
        lock.lock()
        activeRequestCount = max(0, activeRequestCount - 1)
        lastActivityUptime = uptime()
        lock.unlock()
    }

    #if DEBUG
    /// Resets all counters/timestamps. DEBUG-only test helper.
    public func resetForTesting() {
        lock.lock()
        activeRequestCount = 0
        activeConnectionCount = 0
        lastActivityUptime = 0
        lock.unlock()
    }
    #endif
}
