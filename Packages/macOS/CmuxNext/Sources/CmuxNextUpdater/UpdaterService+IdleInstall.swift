import CmuxUpdater

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
        let wasFrontmost = (automaticInstallFrontmost?.isThisApp ?? false) || frontmost().isThisApp
        guard UpdateRelaunchFocus.staysBehind(automatic: automaticInstallInFlight, appIsFrontmost: wasFrontmost),
              let relaunchBehind else { return false }
        log.append("will install \(build)")
        updaterWillInstallUpdate(build: build)
        updaterWillRelaunchApplication()
        log.append("relaunching behind: quitting for the install, then open -g")
        relaunchBehind(Bundle.main.bundleURL) { [weak controller] in controller?.relaunchThroughSparkle() }
        return true
    }
}
