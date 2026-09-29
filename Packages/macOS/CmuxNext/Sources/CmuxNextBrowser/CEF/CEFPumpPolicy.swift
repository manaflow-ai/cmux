import Foundation

/// Timing rules of the external message pump (the cefclient
/// `MainMessageLoopExternalPumpMac` pattern).
nonisolated enum CEFPumpPolicy {
    /// Longest wait CEF may request before the pump runs anyway.
    static let maxDelay: TimeInterval = 1.0 / 30.0
    /// Safety-net interval after a `DoWork` while browsers exist. CEF normally
    /// schedules its own work; this only bounds a missed schedule.
    static let busyFallback: TimeInterval = 1.0 / 30.0
    /// Safety-net interval when no browser is alive (CEF idle after the last
    /// tab closed, which cannot be shut down and restarted).
    static let idleFallback: TimeInterval = 1.0

    /// Delay for a `OnScheduleMessagePumpWork(delay_ms)` request.
    static func delay(forRequestedMilliseconds milliseconds: Int64) -> TimeInterval {
        guard milliseconds > 0 else { return 0 }
        return min(TimeInterval(milliseconds) / 1000, maxDelay)
    }

    static func fallback(liveBrowsers: Int) -> TimeInterval {
        liveBrowsers > 0 ? busyFallback : idleFallback
    }
}
