import CmuxNextWakeups
import Network
public import Foundation

/// The R114 gate (``UpdateFlow``) wired to Sparkle and the App: the card
/// and the Settings badge show only a staged update, a click installs at
/// once unless agents are in a turn, and a quit honors
/// `updates.installOnQuit`.
extension UpdaterService {
    /// The card above Settings, or nil.
    public var card: UpdateCard? {
        flow.card
    }

    /// The footer's update pill, or nil when it does not show.
    public var footerPill: UpdateFooterPill? {
        flow.footerPill(preferences: preferences)
    }

    /// The badge on the Settings item.
    public var showsSettingsBadge: Bool {
        flow.showsSettingsBadge(preferences: preferences)
    }

    /// The Settings row control's label ("Restart to Update"), or nil
    /// when it does not show.
    public var settingsBadgeTitle: String? {
        flow.settingsBadgeTitle(preferences: preferences)
    }

    /// A click on the card: show a failed check's details. The waiting
    /// card's own buttons are ``installNow()`` and ``installLater()``; a
    /// staged update installs from the Settings row control
    /// (``installClicked()``).
    public func cardClicked() {
        switch card {
        case .note(_, isError: true): presentUpdateUI?()
        case .checking, .downloading, .waiting, .installing, .note, nil: break
        }
    }

    /// One click installs (card, Settings badge): at once, or when the
    /// download finishes, or when busy agents finish their turns.
    public func installClicked() {
        syncFlowPhase()
        send(.installRequested)
    }

    /// The waiting card's Install Now: asks before interrupting agents.
    public func installNow() { send(.installNowRequested) }

    /// The waiting card's Later: forget the click, keep the update ready.
    public func installLater() { send(.later) }

    /// The answer of the "install although agents run" dialog.
    public func interruptAnswered(install: Bool) {
        send(install ? .interruptConfirmed : .interruptDeclined)
    }

    /// The App's agent states changed (daemon events).
    public func blockersChanged(_ blockers: UpdateBlockers) {
        guard blockers != flow.blockers else { return }
        send(.blockersChanged(blockers))
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
            cancelStaged()
        }
        return action
    }

    /// A note's display time ended.
    func noteExpired() { send(.noteExpired) }

    func send(_ event: UpdateFlowEvent) {
        for effect in flow.handle(event, preferences: preferences) {
            perform(effect)
        }
    }

    private func perform(_ effect: UpdateFlowEffect) {
        switch effect {
        case .install:
            log.append("gate: installing the staged update")
            installStaged()
        case .confirmInterrupt(let blockers):
            if let confirmInterrupt {
                confirmInterrupt(blockers)
            } else {
                // No dialog host: never interrupt busy agents; the click
                // keeps waiting for them.
                log.append("gate: no dialog host, waiting for \(blockers.busyAgents) agents")
                send(.interruptDeclined)
            }
        case .download:
            log.append("gate: downloading the available update")
            acceptAvailable()
        case .quit:
            break
        }
    }

    /// Feeds ``indicatorPhase`` to the gate when it moved.
    func syncFlowPhase() {
        let phase = indicatorPhase
        guard phase != flow.phase else { return }
        send(.sparkle(phase))
    }

    /// Follows Sparkle's flow through observation (no polling).
    func observeFlowPhase() {
        guard phaseObservation == nil else { return }
        phaseObservation = Task { [weak self] in
            for await _ in Observations({ [weak self] in self?.indicatorPhase }) {
                self?.syncFlowPhase()
            }
        }
    }
}

extension UpdaterService {
    /// Applies `updates.checkAutomatically`, `checkIntervalSeconds`,
    /// `downloadAutomatically` and `meteredNetwork` to Sparkle. No-op
    /// without a driver.
    public func configure(checkAutomatically: Bool, checkInterval: TimeInterval, downloadAutomatically: Bool,
                          metered: UpdateMeteredMode = .deferLowData) {
        downloadSetting = (downloadAutomatically, metered)
        guard let controller else { return }
        controller.setSchedule(automaticChecks: checkAutomatically, interval: checkInterval)
        followNetwork()
        applyDownloadPolicy()
    }

    /// Recomputes whether found updates download by themselves.
    func applyDownloadPolicy() {
        let downloads = UpdateNetworkPolicy.downloadsAutomatically(setting: downloadSetting.enabled, mode: downloadSetting.metered,
                                                                   constrained: network.constrained, expensive: network.expensive)
        guard let controller, controller.downloadsUpdatesInBackground != downloads else { return }
        controller.downloadsUpdatesInBackground = downloads
        log.append("automatic downloads \(downloads ? "on" : "deferred") (constrained \(network.constrained), expensive \(network.expensive))")
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
