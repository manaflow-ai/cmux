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
}

extension CEFStartReport {
    /// When `CefInitialize` started and returned (`cef.initialize_start`, `cef.ready`), as offsets from now in
    /// seconds (negative: before now), for a caller whose clock reads `now` seconds since the process started:
    /// the engine start a page waited for, as launch marks. Empty before CEF is ready.
    ///
    /// - Parameter now: Seconds since the process started, on the caller's clock.
    /// - Returns: Each mark's name and its offset from now.
    public func launchMarks(now: Double) -> [(name: String, offset: Double)] {
        guard let ready = readyAfterLaunch else { return [] }
        var marks: [(name: String, offset: Double)] = []
        if let initialize = initializeDuration {
            let (seconds, attoseconds) = initialize.components
            marks.append(("cef.initialize_start", ready - (Double(seconds) + Double(attoseconds) / 1e18) - now))
        }
        marks.append(("cef.ready", ready - now))
        return marks
    }
}
