public import Foundation

/// What the location bar can jump to (`tab.jump`). `here` moves an open tab into the
/// pane showing the page (its Open Tabs list, cx-jfo7); `closed` reopens a recently
/// closed tab, screen or workspace by its history id (Recently Closed, cx-d0d.60).
public nonisolated enum AgentPaneJumpTarget: String, Sendable {
    case tab, workspace, here, closed
}

extension AgentPaneRequest {
    /// The `NSEvent.timestamp` (seconds of system uptime) of a page input stamped `inputAt` (Unix milliseconds,
    /// `performance.timeOrigin + event.timeStamp`), read against the wall clock and the uptime of one instant.
    /// The page's process stamps its click or key with the platform event's time, as Chrome's renderer does
    /// (`EventMetrics`, cc/metrics/event_metrics.h); the request carries it here a turn after that event's dispatch.
    ///
    /// - Parameters:
    ///   - inputAt: The page's input time, Unix milliseconds.
    ///   - wallNow: Now on the wall clock (`Date()`).
    ///   - uptimeNow: Now in system uptime (`ProcessInfo.processInfo.systemUptime`), read with `wallNow`.
    /// - Returns: The input's uptime, or nil when it is not before now (a clock step, a forged stamp).
    public nonisolated static func uptime(ofPageInputAt inputAt: Double, wallNow: Date = Date(),
                                          uptimeNow: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        let age = wallNow.timeIntervalSince1970 - inputAt / 1_000
        guard age.isFinite, age >= 0 else { return nil }
        return uptimeNow - age
    }
}
