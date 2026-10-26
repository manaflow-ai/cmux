public import CmuxUpdater

extension UpdaterService: UpdateActionDelegate {
    public func updaterRequestsRetryCheckForUpdates() {
        checkForUpdates()
    }

    /// Nothing to save: terminals and layout live in the cmux-tui daemon and
    /// survive the relaunch. Sparkle's terminate goes through the normal
    /// `applicationShouldTerminate` path.
    public func updaterWillRelaunchApplication() {
        let waited = installStartedAt.map { " after \(Int(now().timeIntervalSince($0))) s of install" } ?? ""
        log.append("relaunching for update\(waited)")
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("will_relaunch")
        #endif
        recordRelaunchFocus()
        willRelaunch?()
    }

    /// An install nobody clicked, in an app the user is not in, relaunches behind the app they are
    /// in (``UpdateRelaunchFocus``); every other relaunch clears the record and activates as before.
    func recordRelaunchFocus() {
        let front = frontmost()
        guard UpdateRelaunchFocus.staysBehind(automatic: automaticInstallInFlight, appIsFrontmost: front.isThisApp) else {
            UpdateRelaunchFocus.write(nil, defaults: defaults)
            return
        }
        let record = UpdateRelaunchFocus(targetBuild: installingBuild, recordedAt: now(),
                                         frontmostPID: front.pid, frontmostBundleID: front.bundleID)
        UpdateRelaunchFocus.write(record, defaults: defaults)
        log.append("relaunch stays behind \(front.bundleID ?? "the frontmost app") (automatic install)")
    }

    /// Reads the executable's live blocker provider before Sparkle relaunches.
    public func updaterRelaunchBlockers() -> UpdateRelaunchBlockers {
        relaunchBlockers()
    }
}
