import Foundation

/// The install gate over Sparkle's flow (R114, SIDEBAR-FOOTER-MINIMAL):
/// downloads stay invisible, a staged update is the footer's "Update Ready"
/// pill, and a click or approved idle install passes through the relaunch gate
/// before Sparkle relaunches. A quit installs a staged update unless
/// `updates.installOnQuit` is off. A value: the App feeds events and performs
/// the effects; the decisions are Rust's (cmux-app-ffi src/updater/update_flow.rs,
/// `update_flow.*` over `cmux_updater_call`).
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
    /// Rust's answers for the current state, asked once per state change instead of per read
    /// (SwiftUI reads ``card(downloadsAutomatically:)`` and ``footerPill(preferences:)`` on every
    /// render): the card's kind by `downloadsAutomatically` (false, true), the pill's by `silent`.
    private var cardKinds: [String?] = [nil, nil]
    private var pillKinds: [String?] = [nil, nil]

    public init() { askKinds() }

    public mutating func handle(_ event: UpdateFlowEvent, preferences: UpdatePreferences) -> [UpdateFlowEffect] {
        let request: [String: Any] = [
            "flow": state,
            "event": Self.eventJSON(event),
            "preferences": ["installOnQuit": preferences.installOnQuit, "oneClickInstall": preferences.oneClickInstall],
        ]
        let before = state
        guard let reply = UpdaterRust.call("update_flow.handle", request) as? [String: Any],
              let flow = reply["flow"] as? [String: Any], let effects = reply["effects"] as? [String] else {
            // Rust refused the request (never with these inputs): nothing moves, and a quit still quits.
            return event == .quitRequested ? [.quit(.proceed)] : []
        }
        // Rust keeps the phase's kind; its payload (a transfer, a version, a note) stays here.
        if case .sparkle(let next) = event { phase = next } else if flow["phase"] as? String == "hidden" { phase = .hidden }
        installRequested = flow["installRequested"] as? Bool ?? false
        userAsked = flow["userAsked"] as? Bool ?? false
        downloadAsked = flow["downloadAsked"] as? Bool ?? false
        askPending = flow["askPending"] as? Bool ?? false
        if state as NSDictionary != before as NSDictionary { askKinds() }
        return effects.compactMap(Self.effect)
    }

    /// The person's check while an update waits was answered without a new check (the staged
    /// update card, ``StagedUpdateRefresh``): the next check is not theirs.
    public mutating func askAnswered() {
        guard askPending else { return }
        askPending = false
        askKinds()
    }

    /// The notice card's update status, or nil (`update_flow.card`): what the user asked for (a
    /// check, its download's progress, its result), and a found update that waits for a click
    /// (`updates.downloadAutomatically` off). A scheduled check, its download and its result show
    /// nothing (Lawrence 2026-10-20; Leo 2026-11-03: "it's already downloaded you click this button
    /// to accept the button and restart"). A staged update is never this card.
    ///
    /// - Parameter downloadsAutomatically: `updates.downloadAutomatically`.
    public func card(downloadsAutomatically: Bool) -> UpdateCard? {
        switch (cardKinds[downloadsAutomatically ? 1 : 0], phase) {
        case ("checking", _): return .checking
        case ("downloading", .downloading(let transfer)): return .downloading(transfer)
        case ("available", .available(let version)): return .available(version: version)
        case ("installing", _): return .installing
        case ("note", .note(let note)): return .note(note)
        default: return nil
        }
    }

    /// The footer's update pill (`update_flow.footer_pill`): "Update Ready" while an update is
    /// staged, disabled while it installs; nil otherwise and, for a staged update, under
    /// `updates.notify` silent.
    public func footerPill(preferences: UpdatePreferences) -> UpdateFooterPill? {
        switch pillKinds[preferences.notify == .silent ? 1 : 0] {
        case "ready": .ready
        case "installing": .installing
        default: nil
        }
    }

    /// Asks Rust for the card's and the pill's kinds in this state (`update_flow.card`,
    /// `update_flow.footer_pill`). A download's progress ticks keep the state, so they ask nothing.
    private mutating func askKinds() {
        let flow = state
        cardKinds = [false, true].map { UpdaterRust.call("update_flow.card", ["flow": flow, "downloadsAutomatically": $0]) as? String }
        pillKinds = [false, true].map { UpdaterRust.call("update_flow.footer_pill", ["flow": flow, "silent": $0]) as? String }
    }

    /// The gate's state as Rust reads it: the phase by kind.
    private var state: [String: Any] {
        ["phase": phase.kind, "installRequested": installRequested, "userAsked": userAsked,
         "downloadAsked": downloadAsked, "askPending": askPending]
    }

    private static func eventJSON(_ event: UpdateFlowEvent) -> [String: Any] {
        switch event {
        case .sparkle(let next): ["kind": "sparkle", "next": next.kind]
        case .checkRequested: ["kind": "checkRequested"]
        case .attemptRequested: ["kind": "attemptRequested"]
        case .installRequested: ["kind": "installRequested"]
        case .downloadRequested: ["kind": "downloadRequested"]
        case .quitRequested: ["kind": "quitRequested"]
        case .noteExpired: ["kind": "noteExpired"]
        }
    }

    private static func effect(_ name: String) -> UpdateFlowEffect? {
        switch name {
        case "install": .install
        case "download": .download
        case "quitProceed": .quit(.proceed)
        case "quitCancelPendingInstall": .quit(.cancelPendingInstall)
        default: nil
        }
    }
}

extension UpdateIndicatorPhase {
    /// Downloading or unpacking.
    nonisolated var isDownloading: Bool {
        if case .downloading = self { true } else { false }
    }

    /// The phase's kind, as the Rust gate names it.
    nonisolated var kind: String {
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
