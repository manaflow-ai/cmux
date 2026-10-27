#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
public import CmuxNextWakeups

/// When a ``ChromiumHostSession``'s host quits for having no live page (feature
/// `chromiumHostIdleExit`): its page view in no window for ``after``, timed on the app's one
/// main-thread deadline scheduler.
public struct ChromiumHostIdleExit {
    /// How long the page may be in no window before its host quits (`idleExitAfter`).
    public let after: Duration
    /// The app's deadline scheduler (`AppServices.mainDeadlines`).
    public let deadlines: MainDeadlineScheduler

    public init(after: Duration, deadlines: MainDeadlineScheduler) {
        self.after = after
        self.deadlines = deadlines
    }
}
#endif
