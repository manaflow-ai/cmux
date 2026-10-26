import Foundation

/// The Chromium Host's end while Chromium runs in it (``BrowserBackend/host``, p08-startup-046).
extension CEFRuntime {
    /// The host ended: every page it showed shows `exit`'s crash state (the sad tab, a hidden tab
    /// reloads when shown), every reply still awaited fails with `hostGone`, and the crash log
    /// records the host. Only the host's process ended: cmux keeps running, as Chrome's browser
    /// does when a child process dies (content/browser/renderer_host/render_process_host_impl.cc,
    /// `ProcessDied`). No effect in process, before Chromium runs, or while quitting (quit ends the host).
    func hostEnded(_ exit: BrowserProcessExit) {
        guard hostStart != nil, state == .ready, shutdownSequence == nil else { return }
        logger.error("chromium host ended reason=\(exit.reason.rawValue, privacy: .public) code=\(exit.code ?? 0) tabs=\(self.tabsByBrowser.count)")
        crashLog.append(BrowserCrashRecord(processType: "chromium-host", reason: exit.reason, code: exit.code, source: .process))
        hostReplies?.hostGone()
        for tab in tabsByBrowser.values { tab.rendererTerminated(exit) }
    }

    /// Puts a runtime that has not started in host mode (``adopt(stores:signInCallbacks:waitDeadlines:hostSupervisor:)``):
    /// its start attaches through `supervisor`, and the host's ends reach ``hostEnded(_:)`` when the
    /// supervisor reports them (``ChromiumHostExitReporting``).
    func adoptHost(_ supervisor: any ChromiumHostSupervising) {
        hostStart = CEFHostStart(supervisor: supervisor)
        guard let reporting = supervisor as? any ChromiumHostExitReporting else { return }
        reporting.onHostEnded = { [weak self] exit in self?.hostEnded(exit) }
    }
}
