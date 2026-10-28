import Foundation

/// Renderer and helper process failures: the tab-level record from CEF and
/// the process-level record from `CEFChildProcessMonitor` in process, or from the Chromium Host's
/// HELPER_EXIT in host mode (its helpers are the host's children). Each abnormal end is one
/// `cef.helper_exit` sample (``CEFHelperExitMetric``), the same in both roles: a page renderer
/// from Chromium's termination status once per process, every other helper from the monitor;
/// and one helper-exit report with its pid (``CEFHelperExitReports``).
extension CEFRuntime {
    func recordRendererExit(_ exit: BrowserProcessExit, tab: CEFTab) {
        logger.error("renderer ended reason=\(exit.reason.rawValue, privacy: .public) code=\(exit.code ?? 0) tab=\(tab.id.rawValue, privacy: .public)")
        crashLog.append(BrowserCrashRecord(processType: "renderer", reason: exit.reason, code: exit.code,
                                           tab: tab.id, source: .engine))
    }

    /// A renderer ended (RENDER_TERMINATED, any browser): its one sample comes from the first browser it hosted.
    /// Chromium's status names launch failures, kills, OOM and integrity failures, which a wait status cannot.
    func rendererEnded(_ exit: BrowserProcessExit, end: CEFRendererEnd, client: Int32) {
        guard end != .shared, countsHelperExits else { return }
        helperExits.record(.renderer, exit.reason)
        helperExitReports.rendererEnded(exit, client: client, joinable: childMonitor != nil && hostStart == nil,
                                        pump: helperExitPumpState, deadlines: waitDeadlines)
    }

    /// Quit closes every helper; those ends are expected.
    private var countsHelperExits: Bool { state == .ready && shutdownSequence == nil }

    private var helperExitPumpState: [String: String] { CEFHelperExitReports.pumpState(hostMode: hostStart != nil, stats: pump?.stats) }

    func startChildMonitor() {
        guard childMonitor == nil else { return }
        let monitor = CEFChildProcessMonitor { exit in
            Task { @MainActor in CEFRuntime.shared.childExited(exit) }
        }
        childMonitor = monitor
        monitor.start()
    }

    /// A helper ended: one of the app's (``startChildMonitor()``) or, in host mode, one of the host's (HELPER_EXIT).
    func childExited(_ exit: CEFChildProcessMonitor.Exit) {
        guard countsHelperExits, let reason = exit.abnormalReason else { return }
        let type = exit.isExtension ? "extension" : exit.processType
        logger.error("helper ended type=\(type, privacy: .public) sub=\(exit.subType ?? "-", privacy: .public) pid=\(exit.pid) reason=\(reason.rawValue, privacy: .public) status=\(exit.status)")
        crashLog.append(BrowserCrashRecord(processType: type, subType: exit.subType, pid: exit.pid, reason: reason,
                                           code: Int(exit.status), source: .process))
        let kind = CEFHelperExitMetric.ProcessType(processType: exit.processType, isExtension: exit.isExtension)
        // CEF tells a browser only of its main frame's renderer; the monitor names the browsers whose other frames it hosted.
        for browser in exit.subframeBrowsers { tabsByBrowser[browser]?.subframeRendererEnded(pid: exit.pid) }
        // A page renderer counts in `rendererEnded`; its exit here gives that report its pid.
        guard kind != .renderer else { return helperExitReports.rendererProcessEnded(exit, deadlines: waitDeadlines) }
        helperExits.record(kind, reason)
        helperExitReports.helperEnded(kind, exit, reason: reason, pump: helperExitPumpState)
    }
}
