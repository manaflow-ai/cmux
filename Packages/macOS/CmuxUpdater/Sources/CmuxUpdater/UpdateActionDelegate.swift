/// The host-application actions the updater needs but cannot perform itself.
///
/// This is the dependency-inversion seam between the `CmuxUpdater` package and the app: the
/// package calls up through this protocol instead of reaching `AppDelegate`/`TerminalController`
/// directly. The app's delegate conforms and is injected into ``UpdateController`` (which holds
/// it `weak`).
@MainActor
public protocol UpdateActionDelegate: AnyObject {
    /// The user asked to retry after an update error. The host should re-initiate a check
    /// through its normal entry point.
    func updaterRequestsRetryCheckForUpdates()

    /// Runs before any update relaunch, while the app can still take its time. The host should
    /// capture what the relaunch save needs fresh (the live agent sessions and their resume
    /// bindings), so ``updaterWillRelaunchApplication()`` can save them synchronously. It must
    /// finish in a few seconds; the relaunch waits for it.
    func updaterPrepareForRelaunch() async

    /// Sparkle is about to relaunch the app to finish installing. The host should persist
    /// session state, stop its terminal/runtime, and invalidate restorable state so the
    /// relaunched instance starts cleanly.
    func updaterWillRelaunchApplication()

    /// What relaunching right now would interrupt. An automatic install waits while this is
    /// non-empty (see ``UpdateRelaunchBlockers``).
    func updaterRelaunchBlockers() -> UpdateRelaunchBlockers

    /// How long ago the user last pressed a key, clicked, or moved the pointer, anywhere on the
    /// Mac. An automatic install waits for a quiet moment.
    func updaterTimeSinceLastUserInput() -> Duration
}
