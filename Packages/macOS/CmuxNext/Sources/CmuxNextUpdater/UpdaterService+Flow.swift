public import Foundation

/// The R114 gate (``UpdateFlow``) wired to Sparkle and the App: the card
/// and the Settings badge show only a staged update, a click installs at
/// once unless agents are in a turn, and a quit honors
/// `updates.installOnQuit`.
extension UpdaterService {
    /// The card above Settings, or nil.
    public var card: UpdateCard? {
        flow.card(preferences: preferences, minuteOfDay: minuteOfDay)
    }

    /// The badge on the Settings item.
    public var showsSettingsBadge: Bool {
        flow.showsSettingsBadge(preferences: preferences)
    }

    /// A click on the card: install a staged update, or show a failed
    /// check's details. The waiting card's own buttons are
    /// ``installNow()`` and ``installLater()``.
    public func cardClicked() {
        switch card {
        case .ready, .available: installClicked()
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
        scheduleQuietBoundary()
    }

    /// Re-evaluates the card at the next quiet-hours boundary (one-shot
    /// timer on the injected clock; none without quiet hours).
    func scheduleQuietBoundary() {
        quietTimer?.cancel()
        quietTimer = nil
        let date = now()
        minuteOfDay = Self.minuteOfDay(date)
        guard let quiet = preferences.quietHours else { return }
        let second = Calendar.current.component(.second, from: date)
        let wait = max(1, quiet.minutesToNextBoundary(from: minuteOfDay) * 60 - second)
        let clock = clock
        quietTimer = Task { [weak self] in
            do { try await clock.sleep(for: .seconds(wait)) } catch { return }
            self?.scheduleQuietBoundary()
        }
    }

    static func minuteOfDay(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

extension UpdaterService {
    /// Applies `updates.checkAutomatically`, `checkIntervalSeconds` and
    /// `downloadAutomatically` to Sparkle. No-op without a driver.
    public func configure(checkAutomatically: Bool, checkInterval: TimeInterval, downloadAutomatically: Bool) {
        guard let controller else { return }
        controller.downloadsUpdatesInBackground = downloadAutomatically
        controller.setSchedule(automaticChecks: checkAutomatically, interval: checkInterval)
    }
}
