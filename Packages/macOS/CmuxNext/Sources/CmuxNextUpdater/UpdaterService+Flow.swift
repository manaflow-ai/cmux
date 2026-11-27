import CmuxNextCompat
import CmuxNextWakeups
import CmuxUpdater
import Network
public import Foundation

/// The R114 gate (``UpdateFlow``) wired to Sparkle and the App: the footer
/// pill shows only a staged update, a click installs and relaunches at once
/// (the relaunch keeps every session), and a quit honors
/// `updates.installOnQuit`.
extension UpdaterService {
    /// The notice card's update status, or nil (``UpdateFlow/card``); a
    /// found update the person closed or snoozed (``updateSnooze``) stays
    /// hidden; a check they ask for clears that first (``checkForUpdates()``).
    public var card: UpdateCard? {
        // A found update nobody asked about (downloads wait for a click) is the sidebar footer's quiet
        // Update Available button (``availableButton``), not this card; a check they asked for shows here.
        if let newestCard { return newestCard }
        if let cancelledDownloadCard { return cancelledDownloadCard }
        if let healthCard { return healthCard }
        guard !stagedPulledHeld, let card = flow.card(downloadsAutomatically: true) else { return nil }
        if card == .installing, installCardDismissed { return nil }
        if case .available(let version) = card, updateSnooze.hides(version: version, at: now()) { return nil }
        return card
    }

    /// The sidebar footer's quiet Update Available button: a found update that waits for a click
    /// (`updates.downloadAutomatically` off, or downloads deferred on a metered network); a click
    /// downloads it (``downloadClicked()``), and the staged update then asks before relaunching
    /// (with `updates.oneClickInstall`, it installs and relaunches instead).
    /// Nil otherwise, and for a version the
    /// person closed or snoozed (``updateSnooze``), and while a check the person asked for shows
    /// it on the notice card (``card``).
    public var availableButton: UpdateAvailableButton? {
        guard !flow.userAsked, case .available(let version) = flow.phase, !updateSnooze.hides(version: version, at: now()) else { return nil }
        return UpdateAvailableButton(version: version, restarts: preferences.oneClickInstall)
    }

    /// The footer's update pill, or nil when it does not show.
    public var footerPill: UpdateFooterPill? {
        stagedPulledHeld ? nil : flow.footerPill(preferences: preferences)
    }

    /// The answer to the update-found step (the notice card's Update, the sidebar footer's Update
    /// Available, the sheet's Update): download only. The update then waits on the Update Ready
    /// card, which asks before relaunching (Leo 2026-10-27: "ask before the download + install
    /// step, and likewise for the reboot"). With the opt-in too (a download deferred on a metered
    /// link): the opt-in skips the first ask, never the relaunch's. With `updates.oneClickInstall`
    /// this press is the relaunch's ask too: the update installs and cmux relaunches once it is
    /// staged (``UpdateFlow``). Only the update-found step takes it, so a repeated or late press
    /// (the download already running, or staged) does nothing.
    public func downloadClicked() {
        syncFlowPhase()
        updateClicks += 1
        log.append("download clicked (\(flow.phase))")
        if downloadAgainIfCancelled() { return }
        guard case .available = flow.phase else {
            log.append("update-found answer ignored: nothing waits on that step (\(flow.phase))")
            return
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("download_clicked")
        #endif
        send(.downloadRequested)
    }

    /// Restart to Update (the Update Ready card, the footer pill): install and relaunch, at once
    /// or when the download finishes. `willRelaunch` records keep sessions.
    public func installClicked() {
        if relaunchIntoInstalledBuild() { return }
        syncFlowPhase()
        updateClicks += 1
        log.append("restart to update clicked (\(flow.phase))")
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("install_clicked")
        #endif
        send(.installRequested)
    }

    /// Reads the feed and the pulled list now while an update waits on Update Ready, so a Restart
    /// to Update soon after decides at once (``StagedUpdateRefresh/prefetch(updater:)``). Called
    /// when cmux becomes active; a no-op otherwise.
    public func prefetchForInstallClick() {
        stagedRefresh.prefetch(updater: self)
    }

    /// The quit is decided: with `updates.installOnQuit` off, or a staged build known pulled
    /// (``stagedPulledHeld``), cancel the staged update's installer before the app exits. A pulled
    /// build whose installer this app does not hold (Sparkle's silent cycle still resuming) cannot
    /// be cancelled: the quit proceeds and says so.
    @discardableResult
    public func prepareForQuit() -> UpdateQuitAction {
        syncFlowPhase()
        if case .downloading(let transfer) = flow.phase,
           transfer.stage != .preparing,
           cancelDownloadNow() {
            log.append("quit: cancelling the active update download")
        }
        var action = flow.handle(.quitRequested, preferences: preferences).lazy.compactMap { effect -> UpdateQuitAction? in
            if case .quit(let action) = effect { action } else { nil }
        }.first ?? .proceed
        if rollbackQuitPending {
            // A rollback's quit: a staged update would install over the build just put in place
            // and relaunch forward (cmux#41013 review F2). One staged after the swap is cancelled.
            if let staged = stagedBuild(), !staged.isEmpty {
                log.append(cancelStaged() ? "quit: a rollback quits, cancelled the staged update \(staged)"
                                          : "quit: a rollback quits, but the staged update \(staged) could not be cancelled")
            }
            return .cancelPendingInstall
        }
        if action == .proceed, stagedPulledHeld {
            if cancelStaged() {
                log.append("quit: the staged build was pulled, cancelled it instead of installing on quit")
                action = .cancelPendingInstall
            } else {
                log.append("quit: the staged build was pulled, but no installer was held to cancel; Sparkle installs it on quit")
            }
        } else if action == .cancelPendingInstall {
            log.append("quit: install on quit is off, cancelling the staged update")
            _ = cancelStaged()
        }
        return action
    }

    /// Why the update flow failed, as Sparkle reported it (a failed check, download or install
    /// preflight) in plain words (``UpdateFailureText``), else the read-only probe's failure on a
    /// build without Sparkle; nil otherwise.
    public var failureReason: String? {
        if let controller, disabledReason == nil {
            guard case .error(let failure) = controller.model.effectiveState else { return nil }
            return UpdateFailureText.plain(failure.error)
        }
        return lastProbeError
    }

    /// ``flowMoves`` once the gate holds Sparkle's current phase: the baseline a caller takes
    /// before its request, so only a move the request caused counts.
    public func settledFlowMoves() -> Int {
        syncFlowPhase()
        return flowMoves
    }

    /// A note's display time ended.
    func noteExpired() { send(.noteExpired) }

    func send(_ event: UpdateFlowEvent) {
        for effect in flow.handle(event, preferences: preferences) {
            perform(effect)
        }
        followCardExpiry()
    }

    private func perform(_ effect: UpdateFlowEffect) {
        switch effect {
        case .install:
            stagedRefresh.installStarted()
            installClickedAt = ContinuousClock.now
            picturesAtClick?()
            automaticInstallInFlight = false
            automaticInstallFrontmost = nil
            // The staged build's pre-warm, if it still runs, goes at the click's priority from now on.
            if let run = prewarmRun, run.line == nil { run.urgency.raise() }
            // The newest build of the ring, not a stale staged one (one click, one relaunch); then the
            // staged build's pre-warm, bounded, so its first launch is pre-warmed for a click that came
            // right after the update staged (Leo's NIGHTLY: 3 s).
            stagedRefresh.beforeInstall(updater: self) { [weak self] in
                self?.installAfterPrewarm { [weak self] in self?.installStagedNow() }
            }
        case .download:
            log.append("gate: downloading the available update")
            acceptAvailable()
        case .quit:
            break
        }
    }

    /// Hands the staged update to Sparkle: preflight, the What's New record, the windows, the install.
    private func installStagedNow() {
        log.append("gate: installing the staged update")
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("install_started")
        #endif
        let failure = if let preflightOverride { preflightOverride() } else { installPreflightFailure() }
        if let failure {
            failInstall(failure)
            return
        }
        recordBeforeInstall()
        installStaged()
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("install_handed_to_sparkle")
        #endif
    }

    /// The click that replaced a stale staged build carries over: once Sparkle checks for the
    /// newer build, the click holds it (its download shows, it installs once staged); a failed
    /// check opens the update sheet, so the click never ends in silence.
    func carryInstallClick(_ phase: UpdateIndicatorPhase) {
        guard installAfterSwap else { return }
        switch phase {
        case .checking, .downloading, .available, .ready:
            installAfterSwap = false
            send(.installRequested)
        case .note:
            installAfterSwap = false
            log.append("install click: the newer build's check failed")
            presentUpdateUI?()
        case .hidden, .installing:
            break
        }
    }

    /// Feeds ``indicatorPhase`` to the gate when it moved.
    func syncFlowPhase() {
        stagedRefresh.dropStale(updater: self)
        dropPulledAvailable()
        let phase = indicatorPhase
        guard phase != flow.phase else { return }
        // Nothing found, staged or installing: the next update's clicks count from zero.
        if case .hidden = phase { updateClicks = 0 }
        transferRate.record(phase, at: now())
        if userCheckRunning, phase != .checking { userCheckRunning = false }
        #if DEBUG || CMUX_BENCH_HOOKS
        if phase.harnessName != flow.phase.harnessName { UpdateHarness.mark("phase.\(phase.harnessName)") }
        if case .note = phase, let controller,
           let content = UpdateSheetContent.sparkle(controller.model.effectiveState, current: identity) {
            UpdateHarness.mark("failure_content." + content.buttons.map { String(describing: $0).prefix { $0 != "(" } }.joined(separator: "_"))
        }
        #endif
        flowMoves &+= 1
        let wasInstalling = flow.phase == .installing
        let wasReady = if case .ready = flow.phase { true } else { false }
        let clickedInstall = flow.installRequested
        let previous = flow.phase
        send(.sparkle(phase))
        followCancelledDownload(phase)
        carryInstallClick(phase)
        followNewestFetch(phase, previous: previous)
        followInstall(phase)
        followStagedUpdate(phase)
        stagedRefresh.follow(phase, previous: previous, updater: self)
        tipCheck.refresh(self)
        followReleasePush()
        // A pulled running build read while a check ran is followed once the check ends.
        if case .hidden = phase { followPulled() } else if case .note = phase { followPulled() }
        switch phase {
        case .ready:
            recordStagedUpdate()
            keepRunningBuildForRollback()
            followPulled()
        case .available:
            followPulled()
        case .note where wasInstalling && automaticInstallInFlight:
            // An install nobody clicked failed: nothing opens over the person's work; the
            // log keeps it and the next check offers the update again.
            automaticInstallInFlight = false
            automaticInstallFrontmost = nil
            log.append("automatic install ended without a relaunch (not shown)")
            abandonInstall()
        case .note where wasInstalling || (wasReady && clickedInstall):
            // The install failed: no relaunch comes. The windows come back and the failure's
            // sheet opens with Retry and Download Manually, so the click never ends in silence.
            // A staged update that ends without a click (a background failure) opens nothing.
            log.append("install ended without a relaunch")
            abandonInstall()
            presentUpdateUI?()
            #if DEBUG || CMUX_BENCH_HOOKS
            UpdateHarness.mark("failure_sheet_presented")
            #endif
        case .note(let note) where !flow.userAsked:
            // A scheduled check's result shows nothing; the log keeps it (`cmux update log`).
            log.append("background check: \(note.text) (not shown)")
        default:
            break
        }
    }

    /// Follows Sparkle's flow through observation (no polling).
    func observeFlowPhase() {
        guard phaseObservation == nil else { return }
        phaseObservation = Task { [weak self] in
            for await _ in ObservationStream({ [weak self] in self?.indicatorPhase }) {
                self?.syncFlowPhase()
            }
        }
    }
}

extension UpdaterService {
    /// Applies `updates.checkAutomatically`, `checkIntervalSeconds`,
    /// `downloadAutomatically`, `meteredNetwork` and, when given, `channel`
    /// (``follow(ring:)``) to Sparkle, and when given the idle install's wait cap and quiet window
    /// (`idleInstallMaxWaitSeconds`, `idleInstallQuietSeconds`). The ring is kept without a driver
    /// too (the probe reads it).
    /// - Parameter installWhenIdleMinutes: Update When Idle (`updates.installWhenIdle`, off by default):
    ///   the idle time `updates.installWhenIdleMinutes` when it is on, nil when off.
    public func configure(checkAutomatically: Bool, checkInterval: TimeInterval, downloadAutomatically: Bool,
                          metered: UpdateMeteredMode = .deferLowData, ring: String? = nil,
                          idleInstall: (maxWait: TimeInterval, quiet: TimeInterval)? = nil,
                          installWhenIdleMinutes: TimeInterval? = nil) {
        // Paused (``AutomaticUpdatePause``): the settings keep their values, nothing automatic runs.
        // A shared classic opt-out is preserved for every settings apply. The unmarked value has no
        // provenance, so a later NEXT setting cannot safely clear it without also erasing the classic choice.
        let paused = pausesAutomaticUpdates
        let checkAutomatically = checkAutomatically && !paused && !preservesSharedAutomaticChecksOptOut
        let downloadAutomatically = downloadAutomatically && !paused
        let installWhenIdleMinutes = paused ? nil : installWhenIdleMinutes
        if paused, !settingsApplied { log.append("automatic updates paused: checks, downloads and idle installs only on the person's click") }
        if let ring { follow(ring: ring) }
        installWhenIdle = installWhenIdleMinutes.map { .seconds($0 * 60) }
        if let idleInstall {
            idleInstallQuiet = .seconds(idleInstall.quiet)
            controller?.idleInstallWaitCap = .seconds(idleInstall.maxWait)
            // The longest an automatic install waits silently on a modal, sheet, menu or composition;
            // with Update When Idle, never before its idle time could have passed.
            relaunchMomentHold.surfaceAfter = max(.seconds(idleInstall.maxWait), installWhenIdle ?? .zero)
        }
        // Update When Idle installs what it downloaded: it downloads found updates too.
        downloadSetting = (downloadAutomatically || installWhenIdle != nil, metered)
        settingsApplied = true
        // `updates.downloadAutomatically` downloads found updates and stages them; it never installs
        // them. The app restarts only on the person's click (Restart to Update) unless the person
        // turned on Update When Idle (Leo, 2026-11-19: "maybe even having it as an opt-in option
        // would be pretty interesting. Yeah, like update when idle"); nightly restart policy, 2026-10-27.
        // Its installs wait on ``UpdateRelaunchMomentHold/idleGate`` (the app's Rust rule).
        // The gate first: turning the policy on may hold an update already staged at once.
        let installsWhenIdle = installWhenIdle != nil && idleInstallGate != nil
        relaunchMomentHold.idleGate = installsWhenIdle ? idleInstallGate : nil
        if let controller, controller.installsUpdatesWhenIdle != installsWhenIdle { controller.installsUpdatesWhenIdle = installsWhenIdle }
        stagedRefresh.reschedule(automatic: checkAutomatically, interval: checkInterval, updater: self)
        tipCheck.reschedule(automatic: checkAutomatically, updater: self)
        refreshReleasePush()
        if automaticUpdates != downloadAutomatically { automaticUpdates = downloadAutomatically }
        guard let controller else { return }
        controller.setSchedule(automaticChecks: checkAutomatically, interval: checkInterval)
        followNetwork()
        applyDownloadPolicy()
    }

    /// Follows `updates.channel`: which release ring's appcast items Sparkle and the probe offer.
    /// Takes the setting's raw value (`stable`, `nightly`, `canary`, `dev`); anything else is Nightly.
    /// The first value is the launch's; a later move is the person's pick, so the app checks the
    /// new ring at once instead of at the next scheduled check (a faster ring's newer build
    /// downloads and waits for one restart; a slower ring's way back is ``ringReturn(to:)``).
    public func follow(ring rawValue: String) {
        let ring = UpdateRing(rawValue: rawValue) ?? .nightly
        let picked = ringFollowed
        ringFollowed = true
        guard self.ring != ring else { return }
        self.ring = ring
        controller?.ring = ring
        stagedRefresh.ringMoved()
        log.append("update ring \(ring.rawValue)")
        guard picked else { return }
        log.append("update ring picked: checking \(ring.rawValue) now")
        checkForUpdates()
    }

    /// Recomputes whether found updates download by themselves: the user's
    /// `updates.downloadAutomatically` (a managed configuration can force it)
    /// on the user's metered-network choice, except that an update the
    /// organization requires (`MinimumVersion`) always downloads, and an app
    /// off the organization's `UpdateChannel` downloads none of its own, nor does one under a
    /// forced `DisableAutoUpdate`.
    func applyDownloadPolicy() {
        let required = requiredMinimumVersion != nil
        let enabled = (downloadSetting.enabled || required) && !isOffManagedChannel && !policy.disablesUpdates
        let downloads = (required || !downloadHeldForDeltas) && UpdateNetworkPolicy.downloadsAutomatically(setting: enabled, mode: required ? .download : downloadSetting.metered,
                                                                   constrained: network.constrained || networkPending,
                                                                   expensive: network.expensive || networkPending)
        // The tip app reads its feed every few minutes only where found updates download by
        // themselves and the policy allows updates.
        defer {
            tipCheck.refresh(self)
            stagedRefresh.policyChanged(updater: self)
            refreshReleasePush()
        }
        let resumed = downloads && !downloadsFoundUpdates
        downloadsFoundUpdates = downloads
        if let controller, controller.downloadsUpdatesInBackground != downloads {
            controller.downloadsUpdatesInBackground = downloads
            log.append("automatic downloads \(downloads ? "on" : "deferred") (setting \(downloadSetting.enabled), required \(required), off managed channel \(isOffManagedChannel), constrained \(network.constrained), expensive \(network.expensive), link pending \(networkPending))")
        }
        // Downloads came on (the setting, the link or the policy): an update a check found while they
        // were off downloads now instead of waiting for a click (the driver's own state decides; a
        // no-op when none waits). On the build the person picked it keeps waiting for their click (#36419),
        // unless the organization requires it.
        if resumed && (required || !runsPickedBuild) { acceptAvailable() }
    }

    /// Follows the link's Low Data Mode and cost (path events, no polling). Until the first path
    /// arrives the link counts as metered (``networkPending``).
    func followNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let state = (constrained: path.isConstrained, expensive: path.isExpensive)
            Task { @MainActor in self?.networkChanged(constrained: state.constrained, expensive: state.expensive) }
        }
        networkPending = true
        monitor.start(queue: DispatchQueue(label: "cmux.updates.network"))
        pathMonitor = monitor
    }

    /// A path event: the link's Low Data Mode and cost as the monitor reports them.
    func networkChanged(constrained: Bool, expensive: Bool) {
        let state = (constrained: constrained, expensive: expensive)
        guard networkPending || network != state else { return }
        networkPending = false
        network = state
        applyDownloadPolicy()
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension UpdateIndicatorPhase {
    /// The phase's case name for the update harness's timeline.
    var harnessName: String {
        switch self {
        case .hidden: "hidden"
        case .checking: "checking"
        case .downloading: "downloading"
        case .available: "available"
        case .ready: "ready"
        case .installing: "installing"
        case .note: "note"
        }
    }
}
#endif
