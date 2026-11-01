import CmuxNextWakeups
public import Foundation

/// Which tab opening an existing chat adopts the prewarmed New Tab page (CmuxNextApp's
/// `AgentTabStore.view(for:)` and `NewTabSparePool`; ``AgentPaneView/adoptSession(_:revealTurn:moved:)``).
/// The spare is this Mac's page, connected to this Mac's acpmux, and its handshake is past, so it
/// serves only a chat whose open needs nothing that handshake carries:
/// - a chat of this Mac's acpmux (`thisMac`): not another machine's (its own host), not a Chief
///   home's (`chief:` tabs, and an older subagent tab of this Mac's host the Chief home keeps);
/// - with a session: a tab with none is a New Tab page or a new chat (the spare's own path);
/// - no New Tab page, no seed (a new chat's folder, draft, prompt or surface);
/// - no kept or relaunch wake state (a composer or shell box its own handshake hands over).
public nonisolated struct AgentPaneSpareAdoption: Sendable, Equatable {
    public var thisMac: Bool
    public var session: String?
    public var newTabPage: Bool
    public var seeded: Bool
    public var wake: Bool

    public init(thisMac: Bool, session: String?, newTabPage: Bool, seeded: Bool, wake: Bool) {
        (self.thisMac, self.session, self.newTabPage, self.seeded, self.wake) = (thisMac, session, newTabPage, seeded, wake)
    }

    /// The session the tab's page switches the spare to, nil when the tab gets a page of its own.
    /// `chiefKeeps`: whether this Mac's Chief home keeps a session.
    public func adopted(chiefKeeps: (String) -> Bool) -> String? {
        guard thisMac, let session, !session.isEmpty, !newTabPage, !seeded, !wake, !chiefKeeps(session) else { return nil }
        return session
    }
}

/// Whether the parked spare may serve a tab opening an existing chat (``AgentPaneSpareAdoption``):
/// it answered its handshake, drew, and its client is connected (`pane.clientReady`). Not in
/// Low Power Mode or at serious thermal state: each such open would take the spare and make
/// another page; the tab opens cold instead, and the spare stays for New Tab.
public nonisolated struct AgentPaneSpareReadiness: Sendable, Equatable {
    public var handshake: Bool
    public var painted: Bool
    public var clientReady: Bool
    public var lowPower: Bool
    public var thermal: ProcessInfo.ThermalState

    public init(handshake: Bool, painted: Bool, clientReady: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState) {
        (self.handshake, self.painted, self.clientReady, self.lowPower, self.thermal) = (handshake, painted, clientReady, lowPower, thermal)
    }

    public var servesChat: Bool {
        handshake && painted && clientReady && !lowPower && thermal.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }
}

extension AgentPaneModel {
    /// Whether this page, parked as the spare, may serve a tab opening an existing chat now
    /// (``AgentPaneSpareReadiness``, with this Mac's power and thermal state read now).
    public var servesExistingChat: Bool {
        AgentPaneSpareReadiness(handshake: hasHandshake, painted: hasPainted, clientReady: clientReady,
                                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                thermal: ProcessInfo.processInfo.thermalState).servesChat
    }

    /// Why this page refused to become an existing chat (``adoptSpareSession(_:)``), for the open's trace.
    public var spareRefusal: String {
        sessionId != nil ? "has a session" : newTab == nil ? "no new tab page" : !hasHandshake ? "no handshake"
            : userTouched ? "touched by \(touchedBy ?? "?")" : remoteChat ? "remote chat" : neverPooled ? "never pooled" : "?"
    }
}

/// What an existing chat's open found in the spare pool.
public enum AgentPaneSpareOutcome: Sendable {
    case adopted, empty, unready, refused

    /// The chat-open trace's account of this outcome (bench and debug builds only; a no-op in
    /// Release, which has no `ChatOpenTrace`).
    public func trace(note: @autoclosure () -> String? = nil) {
        #if DEBUG || CMUX_BENCH_HOOKS
        let mark: ChatOpenTrace.Mark = switch self {
        case .adopted: .spareAdopted
        case .empty: .spareEmpty
        case .unready: .spareUnready
        case .refused: .spareRefused
        }
        ChatOpenTrace.shared.mark(mark)
        if let note = note() { ChatOpenTrace.shared.note(note) }
        #endif
    }
}

/// One window's spare page (CmuxNextApp's `NewTabSparePool`), as a pure slot: at most one spare,
/// handed out once; only an empty slot asks for a new one.
public nonisolated struct AgentPaneSpareSlot<Spare> {
    private var spare: Spare?

    public init() {}

    public var shouldWarm: Bool { spare == nil }
    public var count: Int { spare == nil ? 0 : 1 }

    /// Callers park only when ``shouldWarm``; a second spare is refused.
    public mutating func parked(_ value: Spare) {
        guard spare == nil else { return }
        spare = value
    }

    public mutating func take() -> Spare? {
        defer { spare = nil }
        return spare
    }

    public mutating func drop() -> Spare? { take() }

    /// The spare, left in the slot.
    public var peek: Spare? { spare }
}

/// When the spare pool makes the next spare after it handed one out.
public nonisolated enum AgentPaneSpareRefill: Sendable {
    /// On the next main-actor turn: a New Tab or new workspace, so the next Cmd-T finds one.
    case now
    /// Once input is quiet (the pool's idle-input wait): an existing chat took it, and its page is
    /// still attaching that chat. A new page's load on the main thread would land in that open,
    /// and in the next clicks of someone going down the sidebar.
    case whenQuiet
}
