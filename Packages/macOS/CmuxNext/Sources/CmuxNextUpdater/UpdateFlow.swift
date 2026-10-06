import Foundation

/// The install gate over Sparkle's flow (R114): downloads stay invisible,
/// a ready update is the compact control on the Settings row, one click installs unless agents are
/// in a turn (then the click waits for them), and a quit installs a staged
/// update unless `updates.installOnQuit` is off. A pure value: the App
/// feeds events and performs the effects.
nonisolated public struct UpdateFlow: Equatable, Sendable {
    public private(set) var phase: UpdateIndicatorPhase = .hidden
    public private(set) var blockers: UpdateBlockers = .none
    /// The user asked to install; held until the update is staged and no
    /// agent is busy.
    public private(set) var installRequested = false
    /// The user asked to check: checking, downloading and the result show.
    public private(set) var userAsked = false
    /// The "install although work runs" dialog is open.
    public private(set) var confirmationOpen = false

    public init() {}

    public mutating func handle(_ event: UpdateFlowEvent, preferences: UpdatePreferences) -> [UpdateFlowEffect] {
        switch event {
        case .sparkle(let next):
            return sparkleMoved(to: next)
        case .checkRequested:
            userAsked = true
            return []
        case .installRequested:
            switch phase {
            case .ready:
                installRequested = true
                return installIfClear()
            case .downloading, .checking:
                // Installs once staged.
                installRequested = true
                return []
            case .available:
                // Downloads, shows its progress, installs once staged.
                installRequested = true
                userAsked = true
                return [.download]
            case .hidden, .installing, .note:
                return []
            }
        case .installNowRequested:
            guard installRequested, case .ready = phase else { return [] }
            if blockers.isEmpty { return installIfClear() }
            confirmationOpen = true
            return [.confirmInterrupt(blockers)]
        case .interruptConfirmed:
            guard confirmationOpen else { return [] }
            confirmationOpen = false
            guard installRequested, case .ready = phase else { return [] }
            installRequested = false
            return [.install]
        case .interruptDeclined:
            confirmationOpen = false
            return []
        case .later:
            installRequested = false
            confirmationOpen = false
            return []
        case .blockersChanged(let next):
            blockers = next
            guard case .ready = phase else { return [] }
            return installIfClear()
        case .quitRequested:
            guard case .ready = phase, !preferences.installOnQuit else { return [.quit(.proceed)] }
            return [.quit(.cancelPendingInstall)]
        case .noteExpired:
            if case .note = phase { phase = .hidden }
            userAsked = false
            return []
        }
    }

    private mutating func sparkleMoved(to next: UpdateIndicatorPhase) -> [UpdateFlowEffect] {
        phase = next
        switch next {
        case .ready:
            userAsked = false
            return installIfClear()
        case .installing:
            installRequested = false
            confirmationOpen = false
            userAsked = false
            return []
        case .hidden:
            // The flow ended or was cancelled: a held click does not carry
            // over to a later update.
            installRequested = false
            confirmationOpen = false
            return []
        case .note:
            installRequested = false
            confirmationOpen = false
            return []
        case .checking, .downloading, .available:
            return []
        }
    }

    /// Installs when the user asked, the update is staged and no agent is busy.
    private mutating func installIfClear() -> [UpdateFlowEffect] {
        guard installRequested, blockers.isEmpty, case .ready = phase else { return [] }
        installRequested = false
        confirmationOpen = false
        return [.install]
    }

    /// The card above Settings, or nil. Background work never shows; what
    /// the user asked for (a check, a held install) always shows. A found
    /// or staged update is no card: the Settings row's control shows it
    /// (``settingsBadgeTitle(preferences:)``).
    public func card(preferences: UpdatePreferences, minuteOfDay: Int) -> UpdateCard? {
        switch phase {
        case .hidden, .available:
            return nil
        case .checking:
            return userAsked ? .checking : nil
        case .downloading(let progress):
            return userAsked ? .downloading(progress: progress) : nil
        case .note(let text, let isError):
            return userAsked ? .note(text, isError: isError) : nil
        case .installing:
            return .installing
        case .ready(let version):
            guard installRequested, !blockers.isEmpty else { return nil }
            return .waiting(version: version, busyAgents: blockers.busyAgents)
        }
    }

    /// The badge on the Settings item: a staged update, unless silent.
    public func showsSettingsBadge(preferences: UpdatePreferences) -> Bool {
        settingsBadgeTitle(preferences: preferences) != nil
    }

    /// The Settings row control's tooltip and VoiceOver label ("Restart to
    /// Update" for a staged update), or nil when the control does not show.
    public func settingsBadgeTitle(preferences: UpdatePreferences) -> String? {
        preferences.notify == .silent ? nil : phase.badgeTitle
    }
}
