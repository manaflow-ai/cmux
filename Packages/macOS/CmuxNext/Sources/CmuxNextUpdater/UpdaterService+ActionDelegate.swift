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
        recordInstallCheck()
        willRelaunch?()
        // Only a relaunch the person asked for (a click, or a click that took an automatic install
        // over) takes the windows off the screen; its failure and stall paths bring them back. An
        // install nobody clicked relaunches with the windows as they are, as before #22919.
        if !automaticInstallInFlight { hidesForRelaunch?() }
    }

    /// An install nobody clicked, in an app the user was not in when it started (and is not in now),
    /// relaunches behind the app they are in (``UpdateRelaunchFocus``); every other relaunch clears
    /// the record and activates as before.
    func recordRelaunchFocus() {
        let front = frontmost()
        let wasFrontmost = (automaticInstallFrontmost?.isThisApp ?? false) || front.isThisApp
        guard UpdateRelaunchFocus.staysBehind(automatic: automaticInstallInFlight, appIsFrontmost: wasFrontmost) else {
            UpdateRelaunchFocus.write(nil, defaults: defaults)
            return
        }
        let record = UpdateRelaunchFocus(targetBuild: installingBuild, recordedAt: now(),
                                         frontmostPID: front.pid, frontmostBundleID: front.bundleID)
        UpdateRelaunchFocus.write(record, defaults: defaults)
        log.append("relaunch stays behind \(front.bundleID ?? "the frontmost app") (automatic install)")
    }

    /// An automatic install never relaunches while a modal or sheet is up, a menu is open, or text
    /// is mid-composition; it starts at the first moment none holds (``UpdateRelaunchMomentHold``).
    /// A click installs at once, as before.
    public func updaterDefersAutomaticInstall(until ready: @escaping @MainActor () -> Void) -> Bool {
        relaunchMomentHold.hold(ready)
    }

    /// A click, a cancel or the end of the update session took over: the hold goes, with its observers and timer.
    public func updaterEndsAutomaticInstallHold() {
        relaunchMomentHold.cancel()
    }

    /// Reads the executable's live blocker provider before Sparkle relaunches.
    public func updaterRelaunchBlockers() -> UpdateRelaunchBlockers {
        relaunchBlockers()
    }
}
