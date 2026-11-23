import CmuxNextDesignTokens
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

    /// ``adopted(chiefKeeps:)``, counting an existing chat's open that may not ask the spare as a cold build with
    /// its reason in `sources` (every build). An open that may ask and gets no spare is counted by the
    /// spare's own outcome (empty, unready, refused): cold builds in all are `cold` plus those three.
    @MainActor
    public func adoptedCounting(relaunchWake: Bool, chiefKeeps: (String) -> Bool, into sources: AgentPageSources) -> String? {
        let adopted = adopted(chiefKeeps: chiefKeeps)
        if adopted == nil, let session, !session.isEmpty {
            sources.record(.cold(coldReason(relaunchWake: relaunchWake, chiefKeeps: chiefKeeps)))
        }
        return adopted
    }

    /// Why an open of an existing chat (a session is set) builds its page cold rather than asking the spare, in
    /// ``adopted(chiefKeeps:)``'s order. `relaunchWake`: the wake is the relaunch's (``wake`` holds it too).
    /// ``AgentPageColdReason/spareNotTaken`` when the adoption says yes and the spare was not taken.
    public func coldReason(relaunchWake: Bool, chiefKeeps: (String) -> Bool) -> AgentPageColdReason {
        if !thisMac { return .notThisMac }
        if newTabPage { return .newTabPage }
        if seeded { return .seeded }
        if wake { return relaunchWake ? .relaunchWake : .wakeState }
        if let session, !session.isEmpty, chiefKeeps(session) { return .chiefKeeps }
        return .spareNotTaken
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
                                lowPower: LowPowerMode.system.isEnabled,
                                thermal: ProcessInfo.processInfo.thermalState).servesChat
    }

    /// Why this page refused to become an existing chat (``adoptSpareSession(_:)``), for the open's trace.
    public var spareRefusal: String { spareRefusalReason.text }

    /// The refusal's reason (``spareRefusal`` is its trace text; the Release counts key on it).
    public var spareRefusalReason: AgentPaneSpareRefusalReason {
        sessionId != nil ? .hasSession : newTab == nil ? .noNewTabPage : !hasHandshake ? .noHandshake
            : userTouched ? .touched(by: touchedBy ?? hostTouch.by ?? "?") : remoteChat ? .remoteChat : neverPooled ? .neverPooled : .unknown
    }
}

/// What an existing chat's open found in the spare pool.
public enum AgentPaneSpareOutcome: Sendable {
    case adopted, empty, unready, refused

    /// The chat-open trace's account of this outcome (bench and debug builds only; a no-op in
    /// Release, which has no `ChatOpenTrace`).
    /// Also counts the outcome in `sources`, every build; `why` is a refusal's reason.
    @MainActor
    public func trace(note: @autoclosure () -> String? = nil, why: AgentPaneSpareRefusalReason = .unknown, into sources: AgentPageSources) {
        switch self {
        case .adopted: sources.record(.spareAdopted)
        case .empty: sources.record(.spareEmpty)
        case .unready: sources.record(.spareUnready)
        case .refused: sources.record(.spareRefused(why))
        }
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

/// The spare pool's pages (CmuxNextApp's `NewTabSparePool`), as a pure queue of at most ``capacity``: the oldest is
/// handed out first (``peek``, ``take()``); only a queue with room asks for a new one. Two, so a second Cmd-T right
/// after the first also adopts a page that is loaded, as Chrome keeps a spare renderer ready for the next navigation.
public nonisolated struct AgentPaneSpareSlot<Spare> {
    private var spares: [Spare] = []
    /// At least 1. Lowering it keeps the spares already parked until they are handed out.
    public var capacity: Int { didSet { capacity = max(1, capacity) } }

    public init(capacity: Int = 1) {
        self.capacity = max(1, capacity)
    }

    public var shouldWarm: Bool { spares.count < capacity }
    public var count: Int { spares.count }

    /// Callers park only when ``shouldWarm``; a spare past ``capacity`` is refused.
    public mutating func parked(_ value: Spare) {
        guard shouldWarm else { return }
        spares.append(value)
    }

    /// The next spare to hand out, out of the queue.
    public mutating func take() -> Spare? {
        spares.isEmpty ? nil : spares.removeFirst()
    }

    /// Every spare, out of the queue (memory pressure, the last window closing).
    public mutating func dropAll() -> [Spare] {
        defer { spares.removeAll() }
        return spares
    }

    /// The next spare to hand out, left in the queue.
    public var peek: Spare? { spares.first }
    /// Every spare, the next to hand out first.
    public var all: [Spare] { spares }
}

/// When the spare pool makes the next spare after it handed one out.
public nonisolated enum AgentPaneSpareRefill: Sendable {
    /// On the next main-actor turn: a New Tab or new workspace, so the next Cmd-T finds one.
    case now
    /// After the page drew the chat, then the refill's settle, as one background task
    /// (``AgentPaneSpareRefiller/afterPaint(of:)``): an existing chat took it, and its page is still
    /// attaching that chat, so a new page's load on the main thread now would land in that open.
    /// Input does not push it back: the pool's quiet-input wait alone kept the pool empty for
    /// someone who went on scrolling and clicking down the sidebar (decision 2026-11-16).
    case afterPaint
    /// After the frame commit and the settle, with no open to wait for: idle work took it (the next Cmd-N's
    /// reserved workspace), and its page shows nowhere until that key. Mounted hidden, it draws no frame, so a
    /// wait for its next frame would hold the refill until the idle-input backstop, which typing pushes back.
    case idle
}
