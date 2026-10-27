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
        // A found update nobody asked about (downloads wait for a click) is the titlebar's quiet
        // Update Available button (``availableButton``), not this card; a check they asked for shows here.
        guard let card = flow.card(downloadsAutomatically: true) else { return pulledWatch.card }
        if card == .installing, installCardDismissed { return pulledWatch.card }
        if case .available(let version) = card, updateSnooze.hides(version: version, at: now()) { return pulledWatch.card }
        return card
    }

    /// The titlebar's quiet Update Available button: a found update that waits for a click
    /// (`updates.downloadAutomatically` off, or downloads deferred on a metered network); a click
    /// downloads and installs it (``installClicked()``). Nil otherwise, and for a version the
    /// person closed or snoozed (``updateSnooze``), and while a check the person asked for shows
    /// it on the notice card (``card``).
    public var availableButton: UpdateAvailableButton? {
        guard !flow.userAsked, case .available(let version) = flow.phase, !updateSnooze.hides(version: version, at: now()) else { return nil }
        return UpdateAvailableButton(version: version)
    }

    /// The footer's update pill, or nil when it does not show.
    public var footerPill: UpdateFooterPill? {
        flow.footerPill(preferences: preferences)
    }

    /// One click installs (footer pill, palette, `cmux update install`): at
    /// once, or when the download finishes. The relaunch waits only for busy
    /// agents and running commands (the quiet-input and daemon-mirror holds are
    /// for idle installs); `willRelaunch` records keep sessions.
    public func installClicked() {
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("install_clicked")
        #endif
        syncFlowPhase()
        send(.installRequested)
    }

    /// The quit is decided: with `updates.installOnQuit` off, cancel the
    /// staged update's installer before the app exits.
    @discardableResult
    public func prepareForQuit() -> UpdateQuitAction {
        syncFlowPhase()
        let action = flow.handle(.quitRequested, preferences: preferences).lazy.compactMap { effect -> UpdateQuitAction? in
            if case .quit(let action) = effect { action } else { nil }
        }.first ?? .proceed
        if action == .cancelPendingInstall {
            log.append("quit: install on quit is off, cancelling the staged update")
            _ = cancelStaged()
        }
        return action
    }

    /// Why the update flow failed, as Sparkle reported it (a failed check, download or install
    /// preflight), else the read-only probe's failure on a build without Sparkle; nil otherwise.
    public var failureReason: String? {
        if let controller, disabledReason == nil {
            guard case .error(let failure) = controller.model.effectiveState else { return nil }
            return failure.error.localizedDescription
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
            automaticInstallInFlight = false
            automaticInstallFrontmost = nil
            // The newest build of the ring, not a stale staged one (one click, one relaunch).
            stagedRefresh.beforeInstall(updater: self) { [weak self] in self?.installStagedNow() }
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
        willInstallStaged?()
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
        let phase = indicatorPhase
        guard phase != flow.phase else { return }
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
        send(.sparkle(phase))
        carryInstallClick(phase)
        followInstall(phase)
        followStagedUpdate(phase)
        stagedRefresh.follow(phase, updater: self)
        tipCheck.refresh(self)
        followReleasePush()
        switch phase {
        case .ready:
            recordStagedUpdate()
            keepRunningBuildForRollback()
        case .note where wasInstalling && automaticInstallInFlight:
            // An install nobody clicked failed: nothing opens over the person's work; the
            // log keeps it and the next check offers the update again.
            automaticInstallInFlight = false
            automaticInstallFrontmost = nil
            log.append("automatic install ended without a relaunch (not shown)")
        case .note where wasInstalling || (wasReady && clickedInstall):
            // The install failed: no relaunch comes. The windows come back and the failure's
            // sheet opens with Retry and Download Manually, so the click never ends in silence.
            // A staged update that ends without a click (a background failure) opens nothing.
            log.append("install ended without a relaunch")
            installAbandoned?()
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
    public func configure(checkAutomatically: Bool, checkInterval: TimeInterval, downloadAutomatically: Bool,
                          metered: UpdateMeteredMode = .deferLowData, ring: String? = nil,
                          idleInstall: (maxWait: TimeInterval, quiet: TimeInterval)? = nil) {
        if let ring { follow(ring: ring) }
        if let idleInstall {
            idleInstallQuiet = .seconds(idleInstall.quiet)
            controller?.idleInstallWaitCap = .seconds(idleInstall.maxWait)
        }
        downloadSetting = (downloadAutomatically, metered)
        // `updates.downloadAutomatically` downloads found updates and stages them; it never installs
        // them. The app restarts only on the person's click (Restart to Update), so the idle install
        // stays off whatever the download setting says (nightly restart policy, 2026-10-27).
        if let controller, controller.installsUpdatesWhenIdle { controller.installsUpdatesWhenIdle = false }
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
        let downloads = UpdateNetworkPolicy.downloadsAutomatically(setting: enabled, mode: required ? .download : downloadSetting.metered,
                                                                   constrained: network.constrained, expensive: network.expensive)
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
            log.append("automatic downloads \(downloads ? "on" : "deferred") (setting \(downloadSetting.enabled), required \(required), off managed channel \(isOffManagedChannel), constrained \(network.constrained), expensive \(network.expensive))")
        }
        // Downloads came on (the setting, the link or the policy): an update a check found while they
        // were off downloads now instead of waiting for a click (the driver's own state decides; a
        // no-op when none waits).
        if resumed { acceptAvailable() }
    }

    /// Follows the link's Low Data Mode and cost (path events, no polling).
    func followNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let state = (constrained: path.isConstrained, expensive: path.isExpensive)
            Task { @MainActor in
                guard let self, self.network != state else { return }
                self.network = state
                self.applyDownloadPolicy()
            }
        }
        monitor.start(queue: DispatchQueue(label: "cmux.updates.network"))
        pathMonitor = monitor
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
