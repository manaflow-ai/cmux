import CmuxNextTrace
import Foundation

/// How and when this process started CEF (`debug.cef`, check-first-chromium).
public nonisolated struct CEFStartReport: Equatable, Sendable {
    /// `idle`, `loading`, `loaded` (preloaded, not started), `ready`,
    /// `failed` or `shutDown`.
    public var state: String
    /// True once the framework load began before any tab asked for CEF.
    public var preloaded: Bool
    /// What ran `CefInitialize`: `tab` (a Chromium tab needed it) or a warm
    /// start reason (`restoredTab`, `newTabMenu`, `palette`). Nil before.
    public var trigger: String?
    /// Framework `dlopen` time (off the main thread).
    public var loadDuration: Duration?
    /// `CefInitialize` time (main thread).
    public var initializeDuration: Duration?
    /// Seconds since process start when `CefInitialize` returned.
    public var readyAfterLaunch: Double?

    /// Wall-clock seconds from the kernel's start of this process (``LaunchClock/processStart()``,
    /// `PROC_PIDTBSDINFO`) to now: what ``readyAfterLaunch`` holds. The kernel keeps the start only as a wall
    /// time, so this is a wall-clock span; 0 when the clock was set back past the start, nil when the kernel
    /// does not say.
    static func secondsSinceLaunch(_ clock: LaunchClock = LaunchClock()) -> Double? {
        guard let start = clock.processStart() else { return nil }
        // wall-clock: the kernel keeps the process start only as a wall time.
        let now = clock.now().wallNanos
        return now > start.wallNanos ? Double(now - start.wallNanos) / 1e9 : 0
    }
}
