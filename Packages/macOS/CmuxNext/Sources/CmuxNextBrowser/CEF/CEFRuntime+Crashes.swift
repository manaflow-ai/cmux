import Foundation

/// Renderer and helper process failures: the tab-level record from CEF and
/// the process-level record from `CEFChildProcessMonitor`. Each abnormal end is one
/// `cef.helper_exit` sample (``CEFHelperExitMetric``) from the record that sees the process:
/// the monitor in process (it sees renderers too), the tab in host mode (the host owns the helpers).
extension CEFRuntime {
    func recordRendererExit(_ exit: BrowserProcessExit, tab: CEFTab) {
        logger.error("renderer ended reason=\(exit.reason.rawValue, privacy: .public) code=\(exit.code ?? 0) tab=\(tab.id.rawValue, privacy: .public)")
        crashLog.append(BrowserCrashRecord(processType: "renderer", reason: exit.reason, code: exit.code,
                                           tab: tab.id, source: .engine))
        if childMonitor == nil { helperExits.record(.renderer, exit.reason) }
    }

    func startChildMonitor() {
        guard childMonitor == nil else { return }
        let monitor = CEFChildProcessMonitor { exit in
            Task { @MainActor in CEFRuntime.shared.childExited(exit) }
        }
        childMonitor = monitor
        monitor.start()
    }

    func childExited(_ exit: CEFChildProcessMonitor.Exit) {
        // Quit closes every helper; those ends are expected.
        guard state == .ready, shutdownSequence == nil, let reason = exit.abnormalReason else { return }
        let type = exit.isExtension ? "extension" : exit.processType
        logger.error("helper ended type=\(type, privacy: .public) sub=\(exit.subType ?? "-", privacy: .public) pid=\(exit.pid) reason=\(reason.rawValue, privacy: .public) status=\(exit.status)")
        crashLog.append(BrowserCrashRecord(processType: type, subType: exit.subType, pid: exit.pid, reason: reason,
                                           code: Int(exit.status), source: .process))
        helperExits.record(.init(processType: exit.processType, isExtension: exit.isExtension), reason)
    }
}
