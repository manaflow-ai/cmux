@preconcurrency public import Sparkle

/// Opt-in background installs for hosts that never prompt (cmux-next): found updates download
/// silently, and the ready update waits for ``installStagedUpdate()``. Off by default, which
/// keeps the prompt-driven flow and its defaults unchanged. Nothing here writes to defaults.
extension UpdateController {
    /// Whether found updates download without a prompt and wait staged for the user.
    public var installsUpdatesInBackground: Bool {
        get { driver.installsInBackground }
        set {
            driver.installsInBackground = newValue
            guard newValue, disableSparkleSilentStagingIfNeeded() else { return }
            log.append("background install: disabled Sparkle silent staging; using the replaceable app-owned installer")
        }
    }

    /// Whether a staged background update should install automatically once ready. A host that
    /// preserves daemon sessions across app relaunches bypasses the relaunch gate entirely.
    public var installsUpdatesWhenIdle: Bool {
        get { driver.installsWhenIdle }
        set { driver.installsWhenIdle = newValue }
    }

    /// The legacy idle-install wait cap for hosts that opt into ``UpdateRelaunchGate``. cmux-next
    /// leaves the setting available for diagnostics but disables the gate with `holdsUserInstalls`.
    public var idleInstallWaitCap: Duration {
        get { driver.relaunchGate.automaticWaitCap }
        set { driver.relaunchGate.automaticWaitCap = newValue }
    }

    /// Whether this host uses the relaunch gate for user and automatic installs. Set this to false
    /// when the daemon keeps agents and running commands alive across an app relaunch.
    public var holdsUserInstalls: Bool {
        get { driver.holdsUserInstalls }
        set { driver.holdsUserInstalls = newValue }
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
        if driver.quitInstallCommitted, driver.quitInstall != nil {
            log.append("background install: click while the app quits for the install; it reopens updated")
            return
        }
        if driver.installStaged() || driver.installQuitInstallNow() {
            armStagedInstallWatchdog()
            return
        }
        if case .installing(let installing) = model.state, installing.relaunchBlockers != nil {
            // An automatic install the relaunch gate holds: the click is Install Now.
            log.append("background install: click on a held relaunch; installing now")
            installing.retryTerminatingApplication()
            armStagedInstallWatchdog()
            return
        }
        if case .installing(let installing) = model.state, installing.isAutoUpdate {
            log.append("background install: installing the update Sparkle staged silently")
            driver.quitInstallItem = nil
            model.setState(.installing(.init(retryTerminatingApplication: {}, dismiss: {})))
            driver.relaunchIsAutomatic = false
            installing.retryTerminatingApplication()
            armStagedInstallWatchdog()
            return
        }
        setInstallDidNotStartError(diagnostic: "install clicked with no staged update (state=\(model.state))")
    }

    /// Whether the app still means to quit for an automatic install: false once a click, a cancel
    /// or the session's end took it over (``dropQuitInstall()``).
    public var waitsToQuitForInstall: Bool {
        driver.quitInstall != nil
    }

    /// The host's wait for the moment ended and its helper quits the app now: a click no longer
    /// installs through Sparkle (``UpdateActionDelegate/updaterQuitsForAutomaticInstall(build:)``).
    public func commitQuitInstall() {
        driver.commitQuitInstall()
    }

    /// The automatic install the app meant to quit for was taken over (a click, a cancel, the
    /// session's end) while it waited: its held reply goes, so nothing installs it later.
    public func dropQuitInstall() {
        driver.quitInstall = nil
    }

    /// The automatic install the app quit for did not end it (the quit was refused, or the helper
    /// that reopens the app could not start): the update is staged again and waits for a click
    /// (``UpdateActionDelegate/updaterQuitsForAutomaticInstall(build:)``). No-op otherwise.
    public func restageAfterDeclinedQuit() {
        driver.restageAfterDeclinedQuit()
    }

    /// The automatic install the app was to quit for: the user came into the app meanwhile, so
    /// Sparkle installs and relaunches it as for a click (activating). No-op otherwise.
    public func relaunchHeldInstallThroughSparkle() {
        driver.relaunchHeldInstallThroughSparkle()
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
    /// quits) without skipping its version. A legacy silent installer is cancelled and checked
    /// again before it reaches this ready reply. No-op without one; returns whether cancelled.
    @discardableResult
    public func cancelStagedUpdate() -> Bool {
        driver.cancelStaged()
    }

    /// Whether this driver holds the staged update's installer, so ``cancelStagedUpdate()`` would
    /// cancel it (not one still resuming from Sparkle's silent cycle or already installing).
    public var canCancelStagedUpdate: Bool {
        driver.stagedCancel != nil
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
        if driver.refusesBuild?(available.appcastItem.versionString) == true {
            log.append("not downloading \(available.appcastItem.versionString): the host refuses it")
            return
        }
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

    /// The release ring (`updates.channel`) whose appcast items are offered; the next check
    /// uses it. Only the cmux-next feed has rings.
    public var ring: UpdateRing {
        get { driver.ring }
        set { driver.ring = newValue }
    }

    /// Builds at or below this `sparkle:version` are not offered (the build a rollback left).
    public var skipsBuildsThrough: String? {
        get { driver.skipsBuildsThrough }
        set { driver.skipsBuildsThrough = newValue }
    }

    /// Whether the host refuses a found build by its `sparkle:version` (cmux NEXT: a pulled
    /// build): it is dismissed when found, before any download or prompt, and never accepted.
    public var refusesUpdate: (@MainActor (String) -> Bool)? {
        get { driver.refusesBuild }
        set { driver.refusesBuild = newValue }
    }

    /// Refreshes the host's refusal policy before an appcast item is offered or downloaded.
    /// A bounded async read may finish after the appcast, but the item waits for this read.
    public var prepareUpdate: (@MainActor () async -> Void)? {
        get { driver.prepareUpdate }
        set { driver.prepareUpdate = newValue }
    }
}
