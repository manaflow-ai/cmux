import Foundation
public import Observation

/// The approver sheet's draft (client view state, never sent until Approve).
public nonisolated struct ServerApprovalDraft: Sendable, Equatable {
    /// What the code field shows (`XXXX-XXXX` while typing).
    public var code = ""
    public var team: String?
    public var name = ""
    /// Place the user's Chief on this server after Approve (on by default
    /// for a server that runs a Chief brain).
    public var runChief = false

    public init() {}
}

/// The app's projection of one server: the owner's last snapshot, the
/// intents in flight, and the Add Server draft (shared by the Add Server and
/// Pair Another Machine cards). Every server change arrives as an owner
/// snapshot; intents never edit it. The pages draw it
/// (webviews/src/pages/server-cards/server, `ServerPageProvider`).
@Observable
@MainActor
public final class ServerModel {
    public private(set) var connection: ServerConnection = .connecting
    public private(set) var snapshot: ServerSnapshot?
    /// The pending server the approver's code points at.
    public private(set) var candidate: PairingCandidate?
    /// Intents sent and not yet settled, in send order.
    public private(set) var pending: [ServerIntent] = []
    /// The last refusal, cleared on the next send and when the approver's code changes.
    public internal(set) var lastReject: String?
    /// The display name of the last server this device approved, until the Add Server card
    /// closes or opens again.
    public internal(set) var lastApproved: String?
    /// Where the user's Chief runs, when a chief is placed on a server.
    public private(set) var chief: ChiefPlacementStatus?

    /// Client view state.
    public var approval = ServerApprovalDraft()

    private let source: any ServerSource

    public init(source: any ServerSource) {
        self.source = source
    }

    public func start() {
        source.start { [weak self] event in self?.handle(event) }
    }

    /// Stops the source. Its intents in flight never settle once it stops, so they are dropped: a
    /// later `start()` (the menu bar item shown again) never shows one as pending forever. Add
    /// Server's draft, found server and last answer go too: a pairing code from before the stop may
    /// have expired, so the next opening looks it up again.
    public func stop() {
        source.stop()
        pending.removeAll()
        dismissApproval()
    }

    // MARK: - Derived state

    public func isPending(_ match: (ServerIntentKind) -> Bool) -> Bool {
        pending.contains { match($0.kind) }
    }

    /// Whether Approve can go: a complete code, a known candidate, a team
    /// and a name, and no approve in flight.
    public var canApprove: Bool {
        guard let candidate, PairingCode.normalize(approval.code) == candidate.code else { return false }
        guard let team = approval.team, candidate.teams.contains(where: { $0.id == team }) else { return false }
        let name = approval.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !isPending({ if case .approveCode = $0 { true } else { false } })
    }

    // MARK: - Intents

    /// Sends an intent to the owner. Refused while the server is unreachable.
    @discardableResult
    public func send(_ kind: ServerIntentKind) -> Bool {
        // Looking up and approving a code go to the cloud, not to this Mac's
        // server: a Mac that serves nothing still adds a remote server.
        guard connection == .connected || kind.isApprover else {
            lastReject = ServerStrings.unreachable
            return false
        }
        lastReject = nil
        let intent = ServerIntent(kind: kind)
        pending.append(intent)
        source.send(intent)
        return true
    }

    /// The code field changed: keep the edit form, and look the code up
    /// once it is complete.
    public func setApprovalCode(_ text: String) {
        let shown = PairingCode.editing(text)
        guard shown != approval.code else { return }
        approval.code = shown
        // A refusal belongs to the code it answered.
        lastReject = nil
        if candidate?.code != PairingCode.normalize(shown) { candidate = nil }
        if PairingCode.isComplete(shown) { send(.lookupCode(PairingCode.normalize(shown))) }
    }

    public func approve() {
        guard canApprove, let team = approval.team else { return }
        let name = approval.name.trimmingCharacters(in: .whitespacesAndNewlines)
        send(.approveCode(code: PairingCode.normalize(approval.code), team: team, name: name, placeChief: approval.runChief))
    }

    public func cancelApproval() {
        approval = ServerApprovalDraft()
        candidate = nil
    }

    /// The Add Server card closed any way but its Cancel (the panel dismissed, another card took its
    /// place): the typed code stays, but the found server and a lookup still in flight go, so the
    /// next opening looks the code up again (the server's facts may be stale, its code expired).
    public func closeApproval() {
        candidate = nil
        pending.removeAll { if case .lookupCode = $0.kind { true } else { false } }
    }

    // MARK: - Owner events

    func handle(_ event: ServerSourceEvent) {
        switch event {
        case let .connection(state):
            connection = state
        case let .snapshot(next):
            snapshot = next
            connection = .connected
        case let .candidate(found):
            // A late reply for a code the user has since changed, or for a lookup the card's close
            // dropped, is stale.
            guard isPending({ if case .lookupCode = $0 { true } else { false } }) else { return }
            if let found, found.code != PairingCode.normalize(approval.code) { return }
            candidate = found
            guard let found else { return }
            if approval.team == nil || !found.teams.contains(where: { $0.id == approval.team }) {
                approval.team = found.teams.first?.id
            }
            if approval.name.isEmpty { approval.name = found.name }
            approval.runChief = found.isChiefBrain
        case let .settled(key, reject):
            // An answer to an intent no longer pending (dropped by stop() or the card's close) is
            // another session's: its refusal never shows on this one.
            guard let intent = pending.first(where: { $0.key == key }) else { return }
            pending.removeAll { $0.key == key }
            if let reject {
                lastReject = reject
            } else if case let .approveCode(_, _, name, _) = intent.kind {
                lastApproved = name
                cancelApproval()
            }
        case let .chief(status):
            chief = status
        }
    }
}

extension ServerIntentKind {
    /// Intents the cloud answers (pairing a remote server), not this Mac's server.
    var isApprover: Bool {
        switch self {
        case .lookupCode, .approveCode: true
        default: false
        }
    }
}
