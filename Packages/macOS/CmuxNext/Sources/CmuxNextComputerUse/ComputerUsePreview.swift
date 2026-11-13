public import Foundation

/// The live preview of an agent's Computer Use (`computerUse.livePreview`), as the Codex app shows
/// it: a small, live picture of the window the agent drives, in the agent's own cmux surface (its
/// terminal or its chat), while that surface is the one the person looks at. It expands to a larger
/// view, and the person can hide it to a chip and bring it back.
///
/// The video comes from cmux Remote (its `computer-use-preview` app channel): it holds the Screen
/// Recording grant, so the app never asks for its own, and it refuses any window of an app the
/// person keeps private (protected, denied or answered Never). This file is the pure part: which
/// surface a session belongs to, when a preview shows, and what the person chose for it.
public nonisolated enum ComputerUsePreviewSurface: Hashable, Sendable {
    /// A terminal tab: the agent runs in cmux terminal `resource` (`term_…`, `CMUX_TUI_TERMINAL_ID`).
    case terminal(resource: String)
    /// An agent chat: the acpmux session `session` (its tab shows it).
    case chat(session: String)

    /// The surface the engine's session key names: `terminal:<terminal id>:<pid>` for an agent in a
    /// cmux terminal (cmux-tui `agent_computer_use.rs`), else the acpmux session of an agent chat.
    /// A key a server picked for itself (`unbound-…`) names no surface.
    public init?(session: String) {
        guard !session.isEmpty, !session.hasPrefix("unbound-") else { return nil }
        if session.hasPrefix("terminal:") {
            let parts = session.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[1].isEmpty else { return nil }
            self = .terminal(resource: String(parts[1]))
        } else {
            self = .chat(session: session)
        }
    }
}

/// One session the preview may show, as the activity reports it.
public nonisolated struct ComputerUsePreviewCandidate: Equatable, Sendable {
    public var session: String
    public var agent: String?
    public var appName: String?
    public var lastAction: Date
    public var stopped: Bool

    public init(session: String, agent: String? = nil, appName: String? = nil, lastAction: Date, stopped: Bool = false) {
        self.session = session
        self.agent = agent
        self.appName = appName
        self.lastAction = lastAction
        self.stopped = stopped
    }
}

/// When the preview shows. Pure: the controller passes what it sees.
public nonisolated struct ComputerUsePreviewRules: Equatable, Sendable {
    /// How long after its last action an agent's preview stays up, so a short think between
    /// actions does not make it blink away.
    public var lingers: TimeInterval

    public init(lingers: TimeInterval = 15) {
        self.lingers = lingers
    }

    /// The session to preview in `surface`, the one the person looks at: the newest one of that
    /// surface that acted within ``lingers`` and is not stopped. Nil when the setting is off.
    public func session(for surface: ComputerUsePreviewSurface?, among candidates: [ComputerUsePreviewCandidate],
                        enabled: Bool, now: Date) -> ComputerUsePreviewCandidate? {
        guard enabled, let surface else { return nil }
        return candidates
            .filter { !$0.stopped && ComputerUsePreviewSurface(session: $0.session) == surface }
            .filter { now.timeIntervalSince($0.lastAction) < lingers }
            .max { $0.lastAction < $1.lastAction }
    }

    /// When the preview's session stops lingering (the controller looks again then), nil when it
    /// already has.
    public func lingersUntil(_ candidate: ComputerUsePreviewCandidate, now: Date) -> Date? {
        let end = candidate.lastAction.addingTimeInterval(lingers)
        return end > now ? end : nil
    }
}

/// What the person chose for a session's preview: shown small (the default), expanded, or hidden to
/// a chip. Kept per surface in memory only (a new surface starts small).
public nonisolated enum ComputerUsePreviewPresentation: String, Equatable, Sendable {
    case card
    case expanded
    case hidden

    /// The presentation after the person clicks the picture (`expand`), its close or Escape
    /// (`collapse`), its hide button (`hide`), or the chip (`show`).
    public func after(_ action: ComputerUsePreviewGesture) -> ComputerUsePreviewPresentation {
        switch (self, action) {
        case (_, .hide): .hidden
        case (.hidden, .show): .card
        case (.card, .expand): .expanded
        case (.expanded, .collapse): .card
        default: self
        }
    }
}

/// The person's gestures on the preview.
public nonisolated enum ComputerUsePreviewGesture: String, Sendable {
    case expand
    case collapse
    case hide
    case show
}
