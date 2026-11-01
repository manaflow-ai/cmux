import CmuxUpdater
import Foundation

/// A nightly's automatic install (`installsUpdatesWhenIdle`) runs the same preflight as a click
/// (What's New record and rollback copy) before handing the staged update to Sparkle. The app's
/// session-preserving updater relaunches immediately after that handoff.
extension UpdaterService {
    /// False when the preflight fails: the update stays staged for a click and nothing opens.
    public func updaterPrepareAutomaticInstall() -> Bool {
        if let failure = installPreflightFailure() {
            log.append("automatic install skipped: preflight failed (\(failure)); the update waits for a click")
            return false
        }
        recordForAutomaticInstall()
        keepRunningBuildForRollback()
        // A click while the update downloaded (`flow.installRequested`) owns this install: its
        // relaunch activates as a click's does.
        automaticInstallInFlight = !flow.installRequested
        automaticInstallFrontmost = frontmost()
        return true
    }

    /// An install nobody clicked, in an app the user was not in when it started (and is not in
    /// now), reopens behind the app they are in without ever coming forward: the app quits,
    /// Sparkle installs as it exits, and ``UpdateRelaunchBehind`` opens the new build with
    /// `open -g`. The relaunch record (``UpdateRelaunchFocus``) is still written, so the startup
    /// refusal and hand-back stay as a safety net. Every other install lets Sparkle relaunch,
    /// which activates the app as a click expects.
    public func updaterQuitsForAutomaticInstall(build: String) -> Bool {
        guard staysBehindNow, let relaunchBehind else { return false }
        log.append("will install \(build)")
        updaterWillInstallUpdate(build: build)
        log.append("relaunching behind: quitting for the install, then open -g")
        // The relaunch hooks (the record, keep sessions) run only once the helper runs, and only
        // if the user did not come into the app meanwhile; then Sparkle relaunches it, activating.
        relaunchBehind({ [weak self] in
            // The quit ends every sheet (QuitCoordinator): it waits while a modal, sheet, menu or
            // composition is up (``UpdateRelaunchMomentHold``), the helper waiting with it.
            guard let self else { return false }
            guard await self.relaunchMomentHold.waitUntilClear() else {
                // A click, a cancel or the session's end took the install over: nothing installs here.
                self.controller?.dropQuitInstall()
                return false
            }
            // A click took the install over (before the wait began, or as it ended): Sparkle
            // installs and relaunches it now, so the helper must not quit the app as well.
            guard self.controller?.waitsToQuitForInstall ?? true else { return false }
            guard self.staysBehindNow else { return false }
            // In the same main-actor turn as the checks above: no click lands in between.
            self.controller?.commitQuitInstall()
            self.updaterWillRelaunchApplication()
            return true
        }, { [weak self] in self?.quitForInstallDeclined() }, { [weak self] in
            self?.log.append("relaunching behind: the user came into the app; Sparkle relaunches it")
            self?.controller?.relaunchHeldInstallThroughSparkle()
        })
        return true
    }

    /// An install nobody clicked, in an app the user was not in when it started and is not in now.
    var staysBehindNow: Bool {
        let wasFrontmost = (automaticInstallFrontmost?.isThisApp ?? false) || frontmost().isThisApp
        return UpdateRelaunchFocus.staysBehind(automatic: automaticInstallInFlight, appIsFrontmost: wasFrontmost)
    }

    /// The app did not quit for the automatic install (the helper could not start, or the user
    /// kept the app at a quit dialog): the update waits for a click again, and the relaunch record
    /// goes (a later launch the user starts must not stay behind).
    func quitForInstallDeclined() {
        log.append("relaunching behind: the app did not quit; the update waits for a click")
        UpdateRelaunchFocus.write(nil, defaults: defaults)
        automaticInstallInFlight = false
        automaticInstallFrontmost = nil
        // The app keeps running: any window the relaunch took off the screen comes back.
        installAbandoned?()
        controller?.restageAfterDeclinedQuit()
    }
}
