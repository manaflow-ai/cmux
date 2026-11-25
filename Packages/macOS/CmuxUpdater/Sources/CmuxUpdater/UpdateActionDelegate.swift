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

    /// An idle-policy install is staged and about to start with nobody clicking. True when the
    /// host holds it because relaunching now would cut something off (a modal or sheet is up,
    /// text is mid-composition); the host then calls `ready` once, at the first moment none of
    /// that holds, and the install starts then. Meanwhile the update shows as staged, so a click
    /// installs it at once. False starts the install now.
    func updaterDefersAutomaticInstall(until ready: @escaping @MainActor () -> Void) -> Bool

    /// A click, a cancel or the end of the update session took over a held automatic install:
    /// the host drops its hold without calling `ready`.
    func updaterEndsAutomaticInstallHold()

    /// Sparkle is about to install `build` over the running bundle (keep it for rollback).
    func updaterWillInstallUpdate(build: String)

    /// An idle-policy install is about to start with nobody clicking: run what a click runs
    /// first (preflight, records). False keeps the update staged for the user.
    func updaterPrepareAutomaticInstall() -> Bool

    /// An idle-policy install is about to hand `build` to Sparkle. True when the host quits now
    /// and reopens itself without activating: Sparkle relaunches through LaunchServices, which
    /// brings the app to the front before any of its code runs. Sparkle then installs the
    /// update as the app exits, with no relaunch of its own. False lets Sparkle install and
    /// relaunch, as a click does.
    func updaterQuitsForAutomaticInstall(build: String) -> Bool

    /// Whether the app runs in a home LaunchServices would not give back (`HOME` other than the
    /// account's, or `CFFIXED_USER_HOME` set, as in the release rollback drill's throwaway home).
    /// Sparkle relaunches through LaunchServices, which starts the new build with the login
    /// session's environment, so in such a home every relaunch goes through
    /// ``updaterReopensInItsHome(build:declined:)`` instead.
    var updaterRunsInCustomHome: Bool { get }

    /// Sparkle is about to install `build` and relaunch the app, which runs in a custom home
    /// (``updaterRunsInCustomHome``). The host quits and reopens itself in that home; Sparkle
    /// installs as the app exits, with no relaunch of its own. `declined` runs when the host could
    /// not (nothing quit, the app keeps running): the update stays staged, and Sparkle still
    /// installs it when the app quits.
    func updaterReopensInItsHome(build: String, declined: @escaping @MainActor () -> Void)
}

extension UpdateActionDelegate {
    /// Hosts that hold nothing start the automatic install at once.
    public func updaterDefersAutomaticInstall(until ready: @escaping @MainActor () -> Void) -> Bool { false }

    /// Hosts that hold nothing have nothing to drop.
    public func updaterEndsAutomaticInstallHold() {}

    /// Hosts without rollback ignore it.
    public func updaterWillInstallUpdate(build: String) {}

    /// Hosts with nothing to prepare let the automatic install start.
    public func updaterPrepareAutomaticInstall() -> Bool { true }

    /// Hosts that do not reopen themselves let Sparkle relaunch.
    public func updaterQuitsForAutomaticInstall(build: String) -> Bool { false }

    /// Hosts that never run in a custom home let Sparkle relaunch.
    public var updaterRunsInCustomHome: Bool { false }

    /// Hosts that cannot reopen themselves decline.
    public func updaterReopensInItsHome(build: String, declined: @escaping @MainActor () -> Void) { declined() }
}
