/// The host-application actions the updater needs but cannot perform itself.
///
/// This is the dependency-inversion seam between the `CmuxUpdater` package and the app: the
/// package calls up through this protocol instead of reaching `AppDelegate`/`TerminalController`
/// directly. The app's delegate conforms and is injected into ``UpdateController`` (which holds
/// it `weak`). The protocol is main-actor isolated because Sparkle callbacks and cmux update UI
/// state are both main-actor owned.
@MainActor
public protocol UpdateActionDelegate: AnyObject {
    /// The user asked to retry after an update error. The host should re-initiate a check
    /// through its normal entry point.
    ///
    /// - Parameter preservingInstallIntent: Whether the interrupted Sparkle session had already
    ///   moved past update selection into an install/download phase and the retry should
    ///   auto-confirm the same update after Sparkle finds it again.
    func updaterRequestsRetryCheckForUpdates(preservingInstallIntent: Bool)

    /// Sparkle is about to relaunch the app to finish installing. The host should persist
    /// session state, stop its terminal/runtime, and invalidate restorable state so the
    /// relaunched instance starts cleanly.
    func updaterWillRelaunchApplication()
}
