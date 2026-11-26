import Foundation

/// The install gate over Sparkle's flow (R114, SIDEBAR-FOOTER-MINIMAL):
/// downloads stay invisible, a staged update is the footer's "Update Ready"
/// pill, and a click or approved idle install passes through the relaunch gate
/// before Sparkle relaunches. A quit installs a staged update unless
/// `updates.installOnQuit` is off. A pure value: the App feeds events and
/// performs the effects.
///
/// Without automatic download (`updates.downloadAutomatically` off; on by default on every
/// channel) the flow asks twice, as Sparkle's own UI does: a found update waits on the
/// update-found step (``UpdateIndicatorPhase/available(version:)``) until Update
/// (``UpdateFlowEvent/downloadRequested``), and the staged update waits on the Update Ready card
/// until Restart to Update (``UpdateFlowEvent/installRequested``). With `updates.oneClickInstall`
/// (off by default) the first ask is the only one: Update downloads, then installs and relaunches
/// once staged. Hide, or no answer, never relaunches; a quit installs it only with `updates.installOnQuit` on (off by default, the
/// nightly restart policy).
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
    /// The person started this download (Update, Download, an install click, Attempt Update): only
    /// then does its progress show (``card(downloadsAutomatically:)``). A download that follows a check
    /// by itself, the person's check included, stays quiet until it is staged (Lawrence 2026-11-07: "i
    /// think i enabled auto updates but it was automatically downloading updates just now").
    public private(set) var downloadAsked = false
    /// The person's request waits for its check to start: the next
    /// ``UpdateIndicatorPhase/checking`` is theirs. A check that starts
    /// without one is a scheduled check.
    private var askPending = false

    public init() {}

    /// Runs `event` through the gate (Rust, cmux-app-ffi `update_flow.handle`): the gate sees the
    /// phase's kind; the payload (a transfer, a version, a note) stays here.
    public mutating func handle(_ event: UpdateFlowEvent, preferences: UpdatePreferences) -> [UpdateFlowEffect] {
        let request = HandleRequest(
            flow: gate,
            event: GateEvent(event),
            preferences: GatePreferences(installOnQuit: preferences.installOnQuit, oneClickInstall: preferences.oneClickInstall)
        )
        guard let reply = try? UpdaterRust.call("update_flow.handle", request, as: HandleReply.self) else {
            // A request built here is well formed: a failure is a programming error, answered as
            // no move.
            assertionFailure("update_flow.handle refused its request")
            return []
        }
        if case .sparkle(let next) = event { phase = next }
        installRequested = reply.flow.installRequested
        userAsked = reply.flow.userAsked
        downloadAsked = reply.flow.downloadAsked
        askPending = reply.flow.askPending
        return reply.effects.map(\.effect)
    }

    /// The person's check while an update waits was answered without a new check (the staged
    /// update card, ``StagedUpdateRefresh``): the next check is not theirs.
    public mutating func askAnswered() {
        askPending = false
    }

    /// The notice card's update status, or nil (Rust, cmux-app-ffi `update_flow.card`): what the
    /// user asked for (a check, its download's progress, its result), and a found update that
    /// waits for a click (`updates.downloadAutomatically` off), which needs no check. A scheduled
    /// check, its download and its result show nothing; a staged update is never this card (the
    /// staged update card, ``footerPill(preferences:)``). The rules and their sources (Leo
    /// 2026-11-03, 2026-11-04; Lawrence 2026-10-20, 2026-11-07) are on the Rust side.
    ///
    /// - Parameter downloadsAutomatically: `updates.downloadAutomatically`.
    public func card(downloadsAutomatically: Bool) -> UpdateCard? {
        let request = CardRequest(flow: gate, downloadsAutomatically: downloadsAutomatically)
        guard let kind = try? UpdaterRust.call("update_flow.card", request, as: GateCard?.self) else { return nil }
        switch (kind, phase) {
        case (.checking, _): return .checking
        case (.downloading, .downloading(let transfer)): return .downloading(transfer)
        case (.available, .available(let version)): return .available(version: version)
        case (.installing, _): return .installing
        case (.note, .note(let note)): return .note(note)
        // The gate names a kind only from the phase it was given.
        case (.downloading, _), (.available, _), (.note, _): return nil
        }
    }

    /// The footer's update pill (Rust, cmux-app-ffi `update_flow.footer_pill`): "Update Ready"
    /// while an update is staged, disabled while it installs; nil otherwise and, for a staged
    /// update, under `updates.notify` silent.
    public func footerPill(preferences: UpdatePreferences) -> UpdateFooterPill? {
        let request = PillRequest(flow: gate, silent: preferences.notify == .silent)
        guard let kind = try? UpdaterRust.call("update_flow.footer_pill", request, as: GatePill?.self) else { return nil }
        switch kind {
        case .ready: return .ready
        case .installing: return .installing
        case nil: return nil
        }
    }

    /// The gate's state as Rust takes it: the phase's kind, no payload.
    private var gate: GateFlow {
        GateFlow(
            phase: GatePhase(phase),
            installRequested: installRequested,
            userAsked: userAsked,
            downloadAsked: downloadAsked,
            askPending: askPending
        )
    }
}

// The wire of cmux-app-ffi's `update_flow.*` ops (updater/update_flow.rs, camelCase JSON).

private nonisolated enum GatePhase: String, Codable {
    case hidden, checking, downloading, available, ready, installing, note

    init(_ phase: UpdateIndicatorPhase) {
        switch phase {
        case .hidden: self = .hidden
        case .checking: self = .checking
        case .downloading: self = .downloading
        case .available: self = .available
        case .ready: self = .ready
        case .installing: self = .installing
        case .note: self = .note
        }
    }
}

private nonisolated struct GateFlow: Codable {
    var phase: GatePhase
    var installRequested: Bool
    var userAsked: Bool
    var downloadAsked: Bool
    var askPending: Bool
}

private nonisolated struct GateEvent: Encodable {
    let kind: String
    let next: GatePhase?

    init(_ event: UpdateFlowEvent) {
        switch event {
        case .sparkle(let phase): (kind, next) = ("sparkle", GatePhase(phase))
        case .checkRequested: (kind, next) = ("checkRequested", nil)
        case .attemptRequested: (kind, next) = ("attemptRequested", nil)
        case .installRequested: (kind, next) = ("installRequested", nil)
        case .downloadRequested: (kind, next) = ("downloadRequested", nil)
        case .quitRequested: (kind, next) = ("quitRequested", nil)
        case .noteExpired: (kind, next) = ("noteExpired", nil)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(next, forKey: .next)
    }

    private enum CodingKeys: String, CodingKey { case kind, next }
}

private nonisolated struct GatePreferences: Encodable {
    let installOnQuit: Bool
    let oneClickInstall: Bool
}

private nonisolated struct HandleRequest: Encodable {
    let flow: GateFlow
    let event: GateEvent
    let preferences: GatePreferences
}

private nonisolated enum GateEffect: String, Decodable {
    case install, download, quitProceed, quitCancelPendingInstall

    var effect: UpdateFlowEffect {
        switch self {
        case .install: .install
        case .download: .download
        case .quitProceed: .quit(.proceed)
        case .quitCancelPendingInstall: .quit(.cancelPendingInstall)
        }
    }
}

private nonisolated struct HandleReply: Decodable {
    let flow: GateFlow
    let effects: [GateEffect]
}

private nonisolated struct CardRequest: Encodable {
    let flow: GateFlow
    let downloadsAutomatically: Bool
}

private nonisolated enum GateCard: String, Decodable {
    case checking, downloading, available, installing, note
}

private nonisolated struct PillRequest: Encodable {
    let flow: GateFlow
    let silent: Bool
}

private nonisolated enum GatePill: String, Decodable {
    case ready, installing
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
