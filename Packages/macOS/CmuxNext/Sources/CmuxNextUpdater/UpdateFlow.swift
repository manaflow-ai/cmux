import Foundation

/// The install gate over Sparkle's flow (R114, SIDEBAR-FOOTER-MINIMAL):
/// downloads stay invisible, a staged update is the footer's "Update Ready"
/// pill, one click installs and relaunches at once (the relaunch keeps every
/// terminal and agent, so nothing waits for agents and nothing asks), and a
/// quit installs a staged update unless `updates.installOnQuit` is off. A
/// pure value: the App feeds events and performs the effects.
nonisolated public struct UpdateFlow: Equatable, Sendable {
    public private(set) var phase: UpdateIndicatorPhase = .hidden
    /// The user asked to install; held until the update is staged.
    public private(set) var installRequested = false
    /// The user asked to check: checking, downloading and the result show.
    public private(set) var userAsked = false

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
                return installIfStaged()
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
            return installIfStaged()
        case .installing:
            installRequested = false
            userAsked = false
            return []
        case .hidden, .note:
            // The flow ended, failed or was cancelled: a held click does not
            // carry over to a later update.
            installRequested = false
            return []
        case .checking, .downloading, .available:
            return []
        }
    }

    /// Installs when the user asked and the update is staged.
    private mutating func installIfStaged() -> [UpdateFlowEffect] {
        guard installRequested, case .ready = phase else { return [] }
        installRequested = false
        return [.install]
    }

    /// The card above the footer, or nil: only what the user asked for (a
    /// check, its download, its result). A found, staged or installing
    /// update is never a card (``footerPill(preferences:)``).
    public var card: UpdateCard? {
        guard userAsked else { return nil }
        switch phase {
        case .checking: return .checking
        case .downloading(let progress): return .downloading(progress: progress)
        case .note(let text, let isError): return .note(text, isError: isError)
        case .hidden, .available, .ready, .installing: return nil
        }
    }

    /// The footer's update pill: "Update Ready" while an update is staged
    /// (not while it is checked for, found or downloading), disabled while
    /// it installs; nil otherwise and, for a staged update, under
    /// `updates.notify` silent.
    public func footerPill(preferences: UpdatePreferences) -> UpdateFooterPill? {
        switch phase {
        case .ready: preferences.notify == .silent ? nil : .ready
        case .installing: .installing
        case .hidden, .checking, .downloading, .available, .note: nil
        }
    }
}

/// The footer's update pill (SIDEBAR-FOOTER-MINIMAL): its label, and its
/// tooltip and VoiceOver label, which say that the relaunch keeps the
/// terminals and agents (browser pages reload, so they are not named).
nonisolated public enum UpdateFooterPill: Equatable, Sendable {
    /// A staged update: a click installs and relaunches.
    case ready
    /// The click was taken: the pill stays, disabled, until the relaunch.
    case installing

    public var title: String {
        switch self {
        case .ready: UpdaterStrings.readyToInstall
        case .installing: UpdaterStrings.installing
        }
    }

    public var help: String { UpdaterStrings.restartKeepsSessions }
    public var isEnabled: Bool { self == .ready }
}
