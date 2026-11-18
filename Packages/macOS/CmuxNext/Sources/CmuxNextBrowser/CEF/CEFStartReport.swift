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
    /// Measurement arm (CMUX-571 row C): Chromium's start steps (`CEFStartSteps.marks`), as launch marks too.
    public var steps: [CEFStartMark] = []
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
        let raw = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        for step in steps where step.name != "pump" {
            let start = (Double(step.startUptimeNanos) - raw) / 1e9
            marks.append(("cef.step." + step.name, start))
            if step.milliseconds > 0 { marks.append(("cef.step." + step.name + "_end", start + step.milliseconds / 1000)) }
        }
        return marks
    }
}
