#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
import AppKit

/// A host's end as cmux reports it (plans/cmux-next/chrome-parity/p09-observability.md, task 104 (d)), and the
/// session's sends and kills of its host.
extension ChromiumHostSession {
    /// Hands the end of the host `ended` to ``endReports``: every end is counted and forgets the host's files, and
    /// an end by itself (`cause` crash) is a report with the budget's `decision`. Called after the decision's
    /// restart was counted.
    func reportEnd(_ exit: ChromiumHostExit, pid ended: Int32, cause: ChromiumHostEndCause,
                   decision: ChromiumHostRestartPolicy.Decision) {
        let budget = ChromiumHostEndReport.Budget(recentCrashes: policy.recentCrashes, decision: decision.reportName)
        endReports?.hostEnded(pid: ended, exit: exit.pageExit, byItself: cause == .crash, budget: budget)
        endReports?.forget(pid: ended)
    }

    /// SIGKILL to the host this session started (the crash check); its pid, or 0 when none runs.
    /// The pid stays this host's until hostEnded reaps it.
    @discardableResult
    public func killHost() -> Int32 {
        guard pid > 0, connection != nil else { return 0 }
        launcher.kill(pid)
        return pid
    }

    /// Sends a frame to the running host at once (a full socket queues it in
    /// the connection's outbox); a host whose wire broke (the outbox is full,
    /// the socket failed) is ended (its exit restarts it by the policy). Its pid is not reused before
    /// hostEnded reaps it, so the kill reaches only this host.
    @discardableResult
    func send(_ frame: ChromiumHostFrame) -> Bool {
        guard let connection, ChromiumHostConnection.fits(frame) else { return false }
        if connection.send(frame) { return true }
        launcher.kill(pid)
        return false
    }

    /// Reads and hashes the host's code on disk, off the main thread.
    @concurrent nonisolated static func checkSignature(
        of executable: URL, with checker: any ChromiumHostSignatureChecking
    ) async -> ChromiumHostSignatureCheck {
        checker.check(executable)
    }

    /// The page view shows the theme's page background (`PageBackground.themeARGB` of its pane) wherever
    /// the host's pixels are not: while a host starts, restarts or has ended, instead of a hole onto
    /// whatever is behind the pane. The host sends no page color on the wire yet, so the fill stays under
    /// the page once its context shows.
    func fillPageBackground() {
        view.backgroundFill = PageBackground.cgColor(argb: PageBackground.themeARGB(in: view))
    }
}
#endif
