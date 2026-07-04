/// Seam for the system commands the Mac power controller runs, so tests can
/// inject a fake instead of mutating the real machine. Async so callers never
/// block a thread on a slow command (or the loginwindow round-trip an
/// AppleScript sleep can take).
public protocol MacPowerCommandRunning: Sendable {
    /// Run a tool and report whether it exited cleanly (status 0). Used for
    /// fire-and-forget effects such as `osascript … to sleep` or a targeted
    /// `kill` after verifying a `caffeinate` PID.
    @discardableResult
    func run(_ tool: String, _ arguments: [String]) async -> Bool

    /// Run a tool and capture its stdout, or `nil` if it failed to launch. Used
    /// for read-only probes such as `pmset -g assertions`.
    func capture(_ tool: String, _ arguments: [String]) async -> String?
}
