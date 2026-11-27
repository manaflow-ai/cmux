import CmuxNextBrowser
import CmuxNextCrashReporting

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
