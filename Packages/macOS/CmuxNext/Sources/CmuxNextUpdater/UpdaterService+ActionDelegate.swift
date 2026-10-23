public import CmuxUpdater

extension UpdaterService: UpdateActionDelegate {
    public func updaterRequestsRetryCheckForUpdates() {
        checkForUpdates()
    }

    /// Nothing to save: terminals and layout live in the cmux-tui daemon and
    /// survive the relaunch. Sparkle's terminate goes through the normal
    /// `applicationShouldTerminate` path.
    public func updaterWillRelaunchApplication() {
        log.append("relaunching for update")
        #if DEBUG
        UpdateHarness.mark("will_relaunch")
        #endif
        willRelaunch?()
    }

    /// Reads the executable's live blocker provider before Sparkle relaunches.
    public func updaterRelaunchBlockers() -> UpdateRelaunchBlockers {
        relaunchBlockers()
    }
}
