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

    /// Sparkle is about to relaunch the app to finish installing. The host should persist
    /// session state, stop its terminal/runtime, and invalidate restorable state so the
    /// relaunched instance starts cleanly.
    func updaterWillRelaunchApplication()

    /// The user asked to restart now for an update staged by Sparkle's install-on-quit path.
    /// The host should perform the same pre-relaunch cleanup, then terminate the app so Sparkle's
    /// installer-on-quit process can complete without the updater package owning Sparkle's cycle.
    func updaterRequestsRestartForStagedUpdate()

    /// Whether restarting to finish a staged update right now would not interrupt the user.
    /// Consulted by the deferred "restart when idle" loop; the host decides what idle means
    /// (user presence, running agent commands, …).
    func updaterIsSafeToRestartNow() -> Bool
}
