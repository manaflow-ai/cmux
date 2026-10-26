import Foundation

/// The install gate over Sparkle's flow (R114, SIDEBAR-FOOTER-MINIMAL):
/// downloads stay invisible, a staged update is the footer's "Update Ready"
/// pill, and a click or approved idle install passes through the relaunch gate
/// before Sparkle relaunches. A quit installs a staged update unless
/// `updates.installOnQuit` is off. A pure value: the App feeds events and
/// performs the effects.
nonisolated public struct UpdateFlow: Equatable, Sendable {
    public private(set) var phase: UpdateIndicatorPhase = .hidden
    /// The user asked to install; held until the update is staged.
    public private(set) var installRequested = false
    /// The user asked to check: checking, downloading and the result show.
    /// Only the person's own check sets it; a scheduled (background) check
    /// clears it, so it shows nothing until its update is staged (Lawrence
    /// 2026-10-20: "if there is a background check for updates, it should
    /// not be visible to the user").
    public private(set) var userAsked = false
    /// The person's request waits for its check to start: the next
    /// ``UpdateIndicatorPhase/checking`` is theirs. A check that starts
    /// without one is a scheduled check.
    private var askPending = false

    public init() {}

    public mutating func handle(_ event: UpdateFlowEvent, preferences: UpdatePreferences) -> [UpdateFlowEffect] {
        switch event {
        case .sparkle(let next):
            return sparkleMoved(to: next)
        case .checkRequested:
            userAsked = true
            // Joining a check that already runs needs no new start.
            askPending = phase != .checking
            return []
        case .installRequested:
            switch phase {
            case .ready:
                // The staged update card took the click: its own button says
                // Installing…, so the notice card does not take its place.
                installRequested = true
                userAsked = false
                return installIfStaged()
            case .downloading, .checking:
                // Installs once staged; the progress shows meanwhile.
                installRequested = true
                userAsked = true
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

    /// The person's check while an update waits was answered without a new check (the staged
    /// update card, ``StagedUpdateRefresh``): the next check is not theirs.
    public mutating func askAnswered() {
        askPending = false
    }

    private mutating func sparkleMoved(to next: UpdateIndicatorPhase) -> [UpdateFlowEffect] {
        let previous = phase
        phase = next
        switch next {
        case .checking:
            // A check the person did not ask for (scheduled) shows nothing,
            // even while an earlier result of theirs still waits for its x.
            if askPending { askPending = false } else if previous != .checking { userAsked = false }
        case .hidden:
            // A check or download that ended with nothing ends the request:
            // the next scheduled check stays silent. (A note that leaves
            // through ``UpdateFlowEvent/noteExpired`` ends it there.)
            if previous == .checking || previous.isDownloading { userAsked = false }
        case .note, .available, .downloading, .ready, .installing:
            askPending = false
        }
        switch next {
        case .ready:
            userAsked = false
            return installIfStaged()
        case .installing:
            // A person who watched the check and download on the notice card
            // keeps watching it there until the relaunch (``card``).
            installRequested = false
            return []
        case .hidden, .note:
            // The flow ended, failed or was cancelled: a held click does not
            // carry over to a later update.
            installRequested = false
            return []
        case .available:
            // A click held while the check ran: download now, install once staged.
            guard installRequested else { return [] }
            userAsked = true
            return [.download]
        case .checking, .downloading:
            return []
        }
    }

    /// Installs when the user asked and the update is staged.
    private mutating func installIfStaged() -> [UpdateFlowEffect] {
        guard installRequested, case .ready = phase else { return [] }
        installRequested = false
        return [.install]
    }

    /// The notice card's update status, or nil: what the user asked for (a
    /// check, its download, its result), and a found update that waits for
    /// a click (`updates.downloadAutomatically` off), which needs no check.
    /// A scheduled check, its download and its result show nothing.
    /// A staged update is never this card (the staged update card,
    /// ``footerPill(preferences:)``); an install shows here only when the
    /// person followed it here (Attempt Update), so the loading card never
    /// swaps for another card halfway.
    ///
    /// - Parameter downloadsAutomatically: `updates.downloadAutomatically`.
    ///   While on, a found update that is not downloaded yet (the download
    ///   waits for Low Data Mode or a metered link to end) shows nothing until
    ///   it is staged, unless the person asked; off, the found update shows,
    ///   since nothing else would tell the person about it.
    public func card(downloadsAutomatically: Bool) -> UpdateCard? {
        if case .available(let version) = phase, userAsked || !downloadsAutomatically { return .available(version: version) }
        guard userAsked else { return nil }
        switch phase {
        case .checking: return .checking
        case .downloading(let transfer): return .downloading(transfer)
        case .installing: return .installing
        case .note(let note): return .note(note)
        case .hidden, .available, .ready: return nil
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

extension UpdateIndicatorPhase {
    /// Downloading or unpacking.
    nonisolated var isDownloading: Bool {
        if case .downloading = self { true } else { false }
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
