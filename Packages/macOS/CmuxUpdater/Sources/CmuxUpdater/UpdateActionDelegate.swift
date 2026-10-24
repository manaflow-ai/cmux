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

    /// What relaunching right now would interrupt. The updater holds a ready update's
    /// relaunch while this is non-empty (see ``UpdateRelaunchBlockers``).
    func updaterRelaunchBlockers() -> UpdateRelaunchBlockers

    /// Sparkle is about to install `build` over the running bundle (keep it for rollback).
    func updaterWillInstallUpdate(build: String)

    /// An idle-policy install is about to start with nobody clicking: run what a click runs
    /// first (preflight, records). False keeps the update staged for the user.
    func updaterPrepareAutomaticInstall() -> Bool
}

extension UpdateActionDelegate {
    /// Hosts without rollback ignore it.
    public func updaterWillInstallUpdate(build: String) {}

    /// Hosts with nothing to prepare let the automatic install start.
    public func updaterPrepareAutomaticInstall() -> Bool { true }
}
