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

    /// Returns the terminal sessions that would be terminated by an update relaunch.
    func updaterTerminalSessionSummaryForUpdateInstall() -> UpdateInstallGate.TerminalSessionSummary

    /// Asks the host to confirm that the user wants to terminate the given terminal sessions.
    ///
    /// The package keeps the decision policy in ``UpdateInstallGate`` and delegates the actual
    /// UI to the host so `CmuxUpdater` remains independent of AppKit alert presentation.
    /// - Parameter summary: The terminal sessions requiring explicit confirmation.
    /// - Returns: `true` when the user accepted the warning and installation may continue.
    func updaterConfirmTerminalTerminationForUpdateInstall(summary: UpdateInstallGate.TerminalSessionSummary) -> Bool

    /// Sparkle is about to relaunch the app to finish installing. The host should persist
    /// session state, stop its terminal/runtime, and invalidate restorable state so the
    /// relaunched instance starts cleanly.
    func updaterWillRelaunchApplication()
}
