import Foundation

/// Process-wide activity counters for the mobile pairing host: how many
/// interactive RPC requests and live connections are in flight, plus the system
/// uptime of the most recent interactive request. The sidebar git-metadata
/// scheduler reads ``hasRecentActivity(within:)`` / ``quietDelay(for:)`` to back
/// off polling while a paired phone is actively driving the host, and the host's
/// connection and request paths bump the counters as connections open/close and
/// interactive requests begin/end.
///
/// A real instance type replacing the former caseless-enum namespace; the app
/// holds one process-wide default at its composition point and threads it to the
/// decoupled subsystems that share this state. Access is guarded by a small
/// `NSLock` rather than an actor because every reader is a synchronous,
/// non-`async` caller (the sidebar scheduler's `hasRecentActivity` / `quietDelay`
/// run inside synchronous turns and cannot await), and the guarded state is three
/// tiny counters: the sanctioned lock-for-tiny-values-read-by-synchronous-code
/// shape. `@unchecked Sendable` is justified because the `NSLock` serializes every
/// read and write of the three counters.
public final class MobileHostRequestActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRequestCount = 0
    private var activeConnectionCount = 0
    private var lastActivityUptime: TimeInterval = 0

    /// Creates an activity tracker with all counters at zero.
    public init() {}

    /// True while at least one interactive request is in flight.
    public var hasActiveRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeRequestCount > 0
    }

    /// True when a request is in flight, or the last interactive request ended
    /// less than `interval` seconds ago (by system uptime).
    public func hasRecentActivity(within interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeRequestCount == 0 else { return true }
        guard lastActivityUptime > 0 else { return false }
        return ProcessInfo.processInfo.systemUptime - lastActivityUptime < interval
    }

    /// The remaining quiet time before `interval` elapses since the last
    /// interactive request, or `interval` while a request is in flight, or `0`
    /// when there has been no activity yet.
    public func quietDelay(for interval: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard activeRequestCount == 0 else { return interval }
        guard lastActivityUptime > 0 else { return 0 }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastActivityUptime
        return max(0, interval - elapsed)
    }

    /// Records that a new connection opened.
    public func beginConnection() {
        lock.lock()
        activeConnectionCount += 1
        lock.unlock()
    }

    /// Records that a connection closed.
    public func endConnection() {
        lock.lock()
        activeConnectionCount = max(0, activeConnectionCount - 1)
        lock.unlock()
    }

    /// Records that an interactive request began, stamping the activity uptime.
    public func beginRequest() {
        lock.lock()
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
        activeRequestCount += 1
        lock.unlock()
    }

    /// Records that an interactive request ended, stamping the activity uptime.
    public func endRequest() {
        lock.lock()
        activeRequestCount = max(0, activeRequestCount - 1)
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    #if DEBUG
    /// Resets every counter to zero. Test-only.
    public func resetForTesting() {
        lock.lock()
        activeRequestCount = 0
        activeConnectionCount = 0
        lastActivityUptime = 0
        lock.unlock()
    }
    #endif
}
