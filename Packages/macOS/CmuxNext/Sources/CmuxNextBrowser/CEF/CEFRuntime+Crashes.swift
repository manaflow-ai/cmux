import Foundation

/// Renderer and helper process failures: the tab-level record from CEF and
/// the process-level record from `CEFChildProcessMonitor` (in process) or
/// the Chromium host's HELPER_EXIT (host mode, `ChromiumHostProcessMirror`).
extension CEFRuntime {
    func recordRendererExit(_ exit: BrowserProcessExit, tab: CEFTab) {
        logger.error("renderer ended reason=\(exit.reason.rawValue, privacy: .public) code=\(exit.code ?? 0) tab=\(tab.id.rawValue, privacy: .public)")
        crashLog.append(BrowserCrashRecord(processType: "renderer", reason: exit.reason, code: exit.code,
                                           tab: tab.id, source: .engine))
    }

    /// In process only: in host mode the watch is the host's mirror.
    func startChildMonitor() {
        guard helperWatch == nil else { return }
        let monitor = CEFChildProcessMonitor { exit in
            Task { @MainActor in CEFRuntime.shared.childExited(exit) }
        }
        helperWatch = .monitor(monitor)
        monitor.start()
    }

    /// Host mode: the host's mirror (its session's `processes`) reports the
    /// helpers and each tab's renderer clients; no app monitor starts.
    func watchHostHelpers(_ mirror: ChromiumHostProcessMirror) {
        if case .monitor = helperWatch { return }  // in process already: one backend per runtime
        helperWatch = .host(mirror)
    }

    func childExited(_ exit: CEFChildProcessMonitor.Exit) {
        // Quit closes every helper; those ends are expected.
        guard state == .ready, shutdownSequence == nil else { return }
        exit.record(in: crashLog, logger: logger)
    }
}
