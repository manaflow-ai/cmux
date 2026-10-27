import CmuxNextBrowser
import CmuxNextCrashReporting
import Foundation

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
}

extension ChromiumFatalLog {
    /// The log of the previous app run that ran `CefInitialize` in process (p09-observability-084), read for its
    /// crash event at this launch (``CrashReporter/previousRunEvidence(marker:bundleID:home:now:)``). `storage` is
    /// the app's Chromium storage, as `CEFRuntime` picks it.
    nonisolated static func app(previous run: PreviousRun, endedUncleanly: Bool, launched now: Date,
                                storage: CEFProfileStorage = .forApplication(bundleIdentifier: Bundle.main.bundleIdentifier))
        -> ChromiumFatalLog? {
        app(pid: run.pid, launched: run.launched, endedUncleanly: endedUncleanly, now: now,
            logFile: storage.logFile, previousLogFile: storage.previousLogFile)
    }
}
