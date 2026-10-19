@preconcurrency public import Sparkle

/// Opt-in background installs for hosts that never prompt (cmux-next): found updates download
/// silently, and the ready update waits for ``installStagedUpdate()``. Off by default, which
/// keeps the prompt-driven flow and its defaults unchanged. Nothing here writes to defaults.
extension UpdateController {
    /// Whether found updates download without a prompt and wait staged for the user.
    public var installsUpdatesInBackground: Bool {
        get { driver.installsInBackground }
        set { driver.installsInBackground = newValue }
    }

    /// Whether a staged background update should enter the safe idle relaunch gate automatically.
    /// The gate waits for active agent turns, running commands and recent user input.
    public var installsUpdatesWhenIdle: Bool {
        get { driver.installsWhenIdle }
        set { driver.installsWhenIdle = newValue }
    }

    /// The downloaded update waiting for ``installStagedUpdate()``, or nil.
    public var stagedUpdate: SUAppcastItem? {
        driver.stagedItem
    }

    /// Sparkle's scheduled background check, now: with `SUAutomaticallyUpdate` on it downloads
    /// through Sparkle's own silent driver, not this app's driver (the update harness's
    /// `background` run, and what a scheduled check does).
    public func checkInBackground() {
        guard !updater.sessionInProgress else {
            // Sparkle ignores a check while a session runs (the launch probe): run it after.
            log.append("background check queued behind the running session")
            pendingBackgroundCheck = true
            return
        }
        log.append("background check requested")
        updater.checkForUpdatesInBackground()
    }

    /// Installs the staged update and relaunches. The update is staged either by this app's driver
    /// (its held ready reply) or by Sparkle's own silent driver: with `SUAutomaticallyUpdate` on
    /// (a preference the shipped NIGHTLY app shares with this one), a scheduled check never reaches
    /// this app's driver; it downloads, then hands over Sparkle's immediate-install handler through
    /// `willInstallUpdateOnQuit`. Both look the same ("Update ready"), so both must install. If the
    /// app is still running ``installWatchdogTimeout`` after the click, or nothing can install,
    /// the click ends in a visible error that offers a manual download, never a dead button.
    public func installStagedUpdate() {
        if driver.installStaged() {
            armStagedInstallWatchdog()
            return
        }
        if case .installing(let installing) = model.state, installing.isAutoUpdate {
            log.append("background install: installing the update Sparkle staged silently")
            model.setState(.installing(.init(retryTerminatingApplication: {}, dismiss: {})))
            driver.relaunchIsAutomatic = false
            installing.retryTerminatingApplication()
            armStagedInstallWatchdog()
            return
        }
        setInstallDidNotStartError(diagnostic: "install clicked with no staged update (state=\(model.state))")
    }

    /// The app should quit for the installer within ``installWatchdogTimeout``; a click that
    /// leaves it running becomes the "couldn't start the update" error with its retry.
    private func armStagedInstallWatchdog() {
        installWatchdog.arm { [weak self] in
            guard let self else { return }
            self.setInstallDidNotStartError(diagnostic: "the app was still running \(Int(self.installWatchdog.timeoutSeconds))s after the install click (state=\(self.model.state))")
        }
    }

    /// Installs the update downloading in the background as soon as it is ready: the user
    /// clicked while it was still downloading.
    public func installWhenStaged() {
        guard driver.stagedInstall == nil else { return installStagedUpdate() }
        driver.installsWhenStaged = true
    }

    /// Cancels the staged update's pending installer (Sparkle would install it when the app
    /// quits) without skipping its version. No-op without one.
    public func cancelStagedUpdate() {
        driver.cancelStaged()
    }

    /// With ``installsUpdatesInBackground``: whether a found update downloads at once (true,
    /// the default) or waits as ``UpdateState/updateAvailable(_:)`` for ``acceptAvailableUpdate()``.
    public var downloadsUpdatesInBackground: Bool {
        get { driver.downloadsInBackground }
        set { driver.downloadsInBackground = newValue }
    }

    /// Downloads the update that waits for the user; it then stages like a background download.
    public func acceptAvailableUpdate() {
        guard case .updateAvailable(let available) = model.state, !available.reply.isConsumed else { return }
        driver.acceptInBackground(available)
    }

    /// Sparkle's automatic-check schedule (the `SU*` keys; Sparkle persists them and restarts
    /// its cycle). Writes only what changed.
    public func setSchedule(automaticChecks: Bool, interval: TimeInterval) {
        if updater.automaticallyChecksForUpdates != automaticChecks { updater.automaticallyChecksForUpdates = automaticChecks }
        if updater.updateCheckInterval != interval { updater.updateCheckInterval = interval }
    }

    /// A feed URL that replaces the baked `SUFeedURL` for every check (test feeds); nil uses
    /// the baked feed. Sparkle still requires the app's EdDSA key on every item.
    public var feedOverride: String? {
        get { driver.feedOverride }
        set { driver.feedOverride = newValue }
    }

    /// Builds at or below this `sparkle:version` are not offered (the build a rollback left).
    public var skipsBuildsThrough: String? {
        get { driver.skipsBuildsThrough }
        set { driver.skipsBuildsThrough = newValue }
    }
}
