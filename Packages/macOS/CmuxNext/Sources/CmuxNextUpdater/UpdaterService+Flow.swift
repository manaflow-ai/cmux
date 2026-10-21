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
        guard let card = flow.card(downloadsAutomatically: downloadSetting.enabled) else { return pulledWatch.card }
        if case .available(let version) = card, updateSnooze.hides(version: version, at: now()) { return pulledWatch.card }
        return card
    }

    /// The footer's update pill, or nil when it does not show.
    public var footerPill: UpdateFooterPill? {
        flow.footerPill(preferences: preferences)
    }

    /// One click installs (footer pill, palette, `cmux update install`): at
    /// once, or when the download finishes. Running agents never hold it:
    /// the relaunch keeps them (`willRelaunch` records keep sessions).
    public func installClicked() {
        #if DEBUG
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
            log.append("gate: installing the staged update")
            #if DEBUG
            UpdateHarness.mark("install_started")
            #endif
            if let failure = installPreflightFailure() {
                failInstall(failure)
                return
            }
            recordBeforeInstall()
            willInstallStaged?()
            installStaged()
            #if DEBUG
            UpdateHarness.mark("install_handed_to_sparkle")
            #endif
        case .download:
            log.append("gate: downloading the available update")
            acceptAvailable()
        case .quit:
            break
        }
    }

    /// Feeds ``indicatorPhase`` to the gate when it moved.
    func syncFlowPhase() {
        dropStaleStagedUpdate()
        let phase = indicatorPhase
        guard phase != flow.phase else { return }
        if userCheckRunning, phase != .checking { userCheckRunning = false }
        #if DEBUG
        if phase.harnessName != flow.phase.harnessName { UpdateHarness.mark("phase.\(phase.harnessName)") }
        if case .note = phase, let controller,
           let content = UpdateSheetContent.sparkle(controller.model.effectiveState, current: identity) {
            UpdateHarness.mark("failure_content." + content.buttons.map { String(describing: $0).prefix { $0 != "(" } }.joined(separator: "_"))
        }
        #endif
        let wasInstalling = flow.phase == .installing
        let wasReady = if case .ready = flow.phase { true } else { false }
        let clickedInstall = flow.installRequested
        send(.sparkle(phase))
        followStagedUpdate(phase)
        switch phase {
        case .ready:
            recordStagedUpdate()
            keepRunningBuildForRollback()
        case .note where wasInstalling || (wasReady && clickedInstall):
            // The install failed: no relaunch comes. The windows come back and the failure's
            // sheet opens with Retry and Download Manually, so the click never ends in silence.
            // A staged update that ends without a click (a background failure) opens nothing.
            log.append("install ended without a relaunch")
            installAbandoned?()
            presentUpdateUI?()
            #if DEBUG
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
    /// (``follow(ring:)``) to Sparkle. The ring is kept without a driver too (the probe reads it).
    public func configure(checkAutomatically: Bool, checkInterval: TimeInterval, downloadAutomatically: Bool,
                          metered: UpdateMeteredMode = .deferLowData, ring: String? = nil) {
        if let ring { follow(ring: ring) }
        downloadSetting = (downloadAutomatically, metered)
        if automaticUpdates != downloadAutomatically { automaticUpdates = downloadAutomatically }
        guard let controller else { return }
        controller.setSchedule(automaticChecks: checkAutomatically, interval: checkInterval)
        followNetwork()
        applyDownloadPolicy()
    }

    /// Follows `updates.channel`: which release ring's appcast items Sparkle and the probe offer.
    /// Takes the setting's raw value (`stable`, `nightly`, `canary`, `dev`); anything else is Nightly.
    public func follow(ring rawValue: String) {
        let ring = UpdateRing(rawValue: rawValue) ?? .nightly
        guard self.ring != ring else { return }
        self.ring = ring
        controller?.ring = ring
        log.append("update ring \(ring.rawValue)")
    }

    /// Recomputes whether found updates download by themselves: the user's
    /// `updates.downloadAutomatically` (a managed configuration can force it)
    /// on the user's metered-network choice, except that an update the
    /// organization requires (`MinimumVersion`) always downloads, and an app
    /// off the organization's `UpdateChannel` downloads none of its own.
    func applyDownloadPolicy() {
        let required = requiredMinimumVersion != nil
        let enabled = (downloadSetting.enabled || required) && !isOffManagedChannel
        let downloads = UpdateNetworkPolicy.downloadsAutomatically(setting: enabled, mode: required ? .download : downloadSetting.metered,
                                                                   constrained: network.constrained, expensive: network.expensive)
        guard let controller, controller.downloadsUpdatesInBackground != downloads else { return }
        controller.downloadsUpdatesInBackground = downloads
        log.append("automatic downloads \(downloads ? "on" : "deferred") (setting \(downloadSetting.enabled), required \(required), off managed channel \(isOffManagedChannel), constrained \(network.constrained), expensive \(network.expensive))")
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

#if DEBUG
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
