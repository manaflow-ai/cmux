import CmuxUpdater
public import Foundation

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
        if installWhenIdle != nil {
            // The idle relaunch's record (the updater log, `~/Library/Logs/cmux-next/<bundle>-updater.log`, which the
            // app's diagnostics carry): the time is the line's, the reading the gate acted on, the builds it moves between.
            let from = UpdateCard.versionLabel(version: identity.shortVersion, build: identity.build)
            log.append("update when idle: relaunching to install \(stagedVersion ?? "the staged update") (from \(from)); away: \(idleAwayReading ?? "not read")")
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
    /// which activates the app as a click expects, except in a custom home, where the app
    /// reopens itself in front (``reopensInLaunchHome()``).
    public func updaterQuitsForAutomaticInstall(build: String) -> Bool {
        guard staysBehindNow, let relaunchBehind else {
            guard !launchHomeOptions().isEmpty, reopenInFront != nil else { return false }
            log.append("will install \(build)")
            updaterWillInstallUpdate(build: build)
            return reopensInLaunchHome()
        }
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
            guard let self else { return }
            // In a custom home Sparkle's relaunch would leave it: the app reopens itself in front there.
            if self.controller?.waitsToQuitForInstall == true, !self.launchHomeOptions().isEmpty, self.reopensInLaunchHome() { return }
            self.log.append("relaunching behind: the user came into the app; Sparkle relaunches it")
            self.controller?.relaunchHeldInstallThroughSparkle()
        })
        return true
    }

    /// An automatic install the user is in the app for, in an app launched in a custom home:
    /// Sparkle's relaunch (through LaunchServices, with launchd's environment) would bring the new
    /// build back in the account's home, so the app quits and ``reopenInFront`` opens it in front
    /// in its launch home, as for a click's install (``updaterQuitsForInstall(build:)``). The quit
    /// still waits for the moment hold. False when no reopen helper is wired.
    func reopensInLaunchHome() -> Bool {
        guard let reopenInFront else { return false }
        log.append("relaunching in the launch home: the user is in the app; quitting for the install, then open")
        reopenInFront({ [weak self] in
            guard let self else { return false }
            guard await self.relaunchMomentHold.waitUntilClear() else {
                // A click, a cancel or the session's end took the install over: nothing installs here.
                self.controller?.dropQuitInstall()
                return false
            }
            // A click took the install over (Sparkle relaunches it): the helper must not quit as well.
            guard self.controller?.waitsToQuitForInstall ?? true else { return false }
            self.controller?.commitQuitInstall()
            self.updaterWillRelaunchApplication()
            return true
        }, { [weak self] in self?.quitForInstallDeclined() })
        return true
    }

    /// A click's install (Restart to Update, `cmux settings install-available-update`) in an app
    /// launched in a custom home (HOME or CFFIXED_USER_HOME other than the account's, as the
    /// release rollback drill's throwaway home) quits and reopens itself in that home: Sparkle's
    /// relaunch goes through LaunchServices, which starts the new build with launchd's environment
    /// and so in the account's home. Sparkle installs as the app exits, then ``UpdateRelaunchBehind``
    /// opens the new build in front with `open --env`. A launch in the account's own home lets
    /// Sparkle relaunch, as before.
    public func updaterQuitsForInstall(build: String) -> Bool {
        guard !launchHomeOptions().isEmpty, let reopenInFront else { return false }
        log.append("will install \(build)")
        updaterWillInstallUpdate(build: build)
        log.append("relaunching in the launch home: quitting for the install, then open")
        reopenInFront({ [weak self] in
            guard let self else { return false }
            // A second click took the install over (Sparkle relaunches it): the helper must not quit as well.
            guard self.controller?.waitsToQuitForInstall ?? true else { return false }
            self.controller?.commitQuitInstall()
            self.updaterWillRelaunchApplication()
            return true
        }, { [weak self] in self?.quitForInstallDeclined() })
        return true
    }

    /// Wires the helpers that quit and reopen the app (``UpdateRelaunchBehind``): behind for an
    /// automatic install (``relaunchBehind``), in front in the launch home for a click's install in
    /// a custom home (``reopenInFront``). `onQuitRefused` hands the App's quit-refused hook the
    /// helper's stop: a quit the user refuses (a quit dialog's Cancel) stops the helper and stages
    /// the update again.
    public func useReopenHelpers(app: URL, bundleIdentifier: String,
                                 onQuitRefused: @escaping @MainActor (_ stop: @escaping @MainActor () -> Void) -> Void) {
        relaunchBehind = { willQuit, declined, inFront in
            let behind = UpdateRelaunchBehind(app: app, bundleIdentifier: bundleIdentifier)
            onQuitRefused { behind.quitRefused() }
            behind.start(willQuit: willQuit, declined: declined, inFront: inFront)
        }
        reopenInFront = { willQuit, declined in
            let reopen = UpdateRelaunchBehind(app: app, bundleIdentifier: bundleIdentifier, inBackground: false)
            onQuitRefused { reopen.quitRefused() }
            reopen.start(willQuit: willQuit, declined: declined, inFront: {})
        }
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
        if automaticInstallInFlight, installWhenIdle != nil {
            // Update When Idle tries again once the person is still away, after a backoff (not every second).
            idleDeclinedInstalls += 1
            idleDeclinedAt = Date()
            log.append("update when idle: install \(idleDeclinedInstalls) in a row declined; backing off before the next try")
        }
        UpdateRelaunchFocus.write(nil, defaults: defaults)
        automaticInstallInFlight = false
        automaticInstallFrontmost = nil
        // The app keeps running: any window the relaunch took off the screen comes back.
        abandonInstall()
        controller?.restageAfterDeclinedQuit()
    }
}
