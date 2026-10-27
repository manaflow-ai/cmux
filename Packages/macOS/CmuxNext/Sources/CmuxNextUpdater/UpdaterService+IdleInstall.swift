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
}
