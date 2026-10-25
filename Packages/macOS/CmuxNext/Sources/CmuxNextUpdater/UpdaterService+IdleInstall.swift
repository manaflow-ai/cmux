import CmuxUpdater

/// A nightly's automatic install (`installsUpdatesWhenIdle`) runs what the install click runs
/// (preflight, the What's New record, the rollback copy) before the relaunch gate takes it,
/// without hiding any window or opening anything.
extension UpdaterService {
    /// False when the preflight fails: the update stays staged for a click and nothing opens.
    public func updaterPrepareAutomaticInstall() -> Bool {
        if let failure = installPreflightFailure() {
            log.append("automatic install skipped: preflight failed (\(failure)); the update waits for a click")
            return false
        }
        recordForAutomaticInstall()
        keepRunningBuildForRollback()
        automaticInstallInFlight = true
        return true
    }
}
