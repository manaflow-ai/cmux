import CmuxNextBrowser
import CmuxNextCrashReporting
import CmuxNextWakeups

extension AppRunMarker {
    /// Chromium resets every signal action when `CefInitialize` runs, and
    /// it can still fail afterwards. After CEF starts or fails to start,
    /// this puts back the run marker's fatal-signal handlers, then Sentry's
    /// (which call the marker's after their report), then `QuitSignal`'s.
    /// `marker` is nil outside the app process (no handlers of its own).
    static func keepSignalHandlers(_ marker: AppRunMarker?, across engine: CEFEngine, reporter: CrashReporter?) {
        let reinstall: () -> Void = {
            marker?.installHandlers()
            reporter?.reassertSignalHandlers()
            // Chromium resets signal actions at start and catches SIGINT and
            // SIGHUP itself; they stay requested quits.
            QuitSignal.reclaim()
        }
        engine.onReady = reinstall
        engine.onStartFailed = reinstall
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Writes a crash report on the files lane for each end of the Chromium Host that was not a clean exit
    /// (p01-process-085): its signal or exit code, what it ran and its log's last lines without URLs. It stands for
    /// the crash log's `chromium-host` record of that end, which writes no report (``CrashRecoveryService/observe(_:)``).
    static func reportHostCrashes(of supervising: (any ChromiumHostSupervising)?, writer: CrashReportWriter, work: BackgroundWork) {
        guard let supervisor = supervising as? ChromiumHostSupervisor else { return }
        supervisor.onHostCrash = { record in
            let data = CrashReportWriter.encode(writer.report(for: record))
            work.post(.bestEffort, mayBlock: .files) { _ = writer.write(data, name: "chromium-host", date: record.date) }
        }
    }
    #endif
}
