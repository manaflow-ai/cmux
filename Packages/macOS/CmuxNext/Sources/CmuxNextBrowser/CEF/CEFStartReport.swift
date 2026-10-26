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

    /// Seconds from the process start to now on `clock` (the launch marks' clock: the kernel's process
    /// start, PROC_PIDTBSDINFO, read when asked rather than in a static initializer); nil when the kernel
    /// does not answer.
    static func secondsSinceLaunch(_ clock: LaunchClock = LaunchClock()) -> Double? {
        guard let start = clock.processStart() else { return nil }
        let now = clock.now().uptimeNanos
        return now > start.uptimeNanos ? Double(now - start.uptimeNanos) / 1e9 : 0
    }
}
