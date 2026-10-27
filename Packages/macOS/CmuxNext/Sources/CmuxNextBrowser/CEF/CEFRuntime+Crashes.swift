import Foundation

/// Renderer and helper process failures: the tab-level record from CEF and
/// the process-level record from `CEFChildProcessMonitor`. Each abnormal end is one
/// `cef.helper_exit` sample (``CEFHelperExitMetric``) and one ``BrowserCrashLog/helperExited(_:)``
/// (the App's helper-exit Sentry event), the same in both roles: a page renderer from Chromium's
/// termination status once per process, every other helper from the monitor, with its pid.
extension CEFRuntime {
    func recordRendererExit(_ exit: BrowserProcessExit, tab: CEFTab) {
        logger.error("renderer ended reason=\(exit.reason.rawValue, privacy: .public) code=\(exit.code ?? 0) tab=\(tab.id.rawValue, privacy: .public)")
        crashLog.append(BrowserCrashRecord(processType: "renderer", reason: exit.reason, code: exit.code,
                                           tab: tab.id, source: .engine))
    }

    /// A renderer ended (RENDER_TERMINATED, any browser): its one end comes from the first browser it hosted.
    /// Chromium's status names launch failures, kills, OOM and integrity failures, which a wait status cannot;
    /// it names no pid.
    func rendererEnded(_ exit: BrowserProcessExit, end: CEFRendererEnd) {
        guard end != .shared, countsHelperExits else { return }
        helperEnded(.renderer, chromiumType: "renderer", subType: nil, pid: nil, reason: exit.reason, code: exit.code)
    }

    /// Quit closes every helper; those ends are expected.
    private var countsHelperExits: Bool { state == .ready && shutdownSequence == nil }

    func startChildMonitor() {
        guard childMonitor == nil else { return }
        let monitor = CEFChildProcessMonitor { exit in
            Task { @MainActor in CEFRuntime.shared.childExited(exit) }
        }
        childMonitor = monitor
        monitor.start()
    }

    func childExited(_ exit: CEFChildProcessMonitor.Exit) {
        guard countsHelperExits, let reason = exit.abnormalReason else { return }
        let type = exit.isExtension ? "extension" : exit.processType
        logger.error("helper ended type=\(type, privacy: .public) sub=\(exit.subType ?? "-", privacy: .public) pid=\(exit.pid) reason=\(reason.rawValue, privacy: .public) status=\(exit.status)")
        crashLog.append(BrowserCrashRecord(processType: type, subType: exit.subType, pid: exit.pid, reason: reason,
                                           code: Int(exit.status), source: .process))
        let kind = CEFHelperExitMetric.ProcessType(processType: exit.processType, isExtension: exit.isExtension)
        guard kind != .renderer else { return } // a page renderer's end is `rendererEnded`'s
        helperEnded(kind, chromiumType: exit.processType, subType: exit.subType, pid: exit.pid, reason: reason,
                    code: Int(exit.status))
    }

    /// A helper process's one abnormal end: its `cef.helper_exit` sample and its helper-exit report.
    private func helperEnded(_ kind: CEFHelperExitMetric.ProcessType, chromiumType: String, subType: String?, pid: Int32?,
                             reason: BrowserProcessExit.Reason, code: Int?) {
        helperExits.record(kind, reason)
        crashLog.helperExited(BrowserHelperExit(processType: kind.reportName, chromiumType: chromiumType, subType: subType,
                                                pid: pid, reason: reason, code: code, pump: helperExitPumpState))
    }

    /// The message pump's numbers since CefInitialize (``CEFPumpStats``). In host mode the Chromium host
    /// runs the pump and keeps its numbers (p09-observability task 104): only the mode.
    private var helperExitPumpState: [String: String] {
        if hostStart != nil { return ["mode": "host"] }
        guard let stats = pump?.stats else { return ["mode": "none"] }
        return [
            "mode": "in_process",
            "work_runs": String(stats.workRuns),
            "long_work_runs": String(stats.longWorkRuns),
            "pass_p99_ms": String(format: "%.1f", stats.passMillisecondsP99),
        ]
    }
}

private extension CEFHelperExitMetric.ProcessType {
    /// ``BrowserHelperExit/processType``: a fixed name per kind.
    var reportName: String {
        switch self {
        case .other: "other"
        case .renderer: "renderer"
        case .extensionRenderer: "extension"
        case .gpu: "gpu"
        case .utility: "utility"
        }
    }
}
