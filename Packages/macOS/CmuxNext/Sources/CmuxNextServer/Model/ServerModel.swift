import Foundation
public import Observation

/// The overall line the panel shows, most important state first.
public nonisolated enum ServerOverall: Sendable, Equatable {
    case unavailable
    case off
    case unpaired
    case pairing
    case serving
    case attention(HealthSeverity)
}

/// The approver sheet's draft (client view state, never sent until Approve).
public nonisolated struct ServerApprovalDraft: Sendable, Equatable {
    /// What the code field shows (`XXXX-XXXX` while typing).
    public var code = ""
    public var team: String?
    public var name = ""

    public init() {}
}

/// The app's projection of one server: the owner's last snapshot, the
/// intents in flight, and client view state (the approver draft). Every
/// server change arrives as an owner snapshot; intents never edit it.
@Observable
@MainActor
public final class ServerModel {
    public private(set) var connection: ServerConnection = .connecting
    public private(set) var snapshot: ServerSnapshot?
    /// The pending server the approver's code points at.
    public private(set) var candidate: PairingCandidate?
    /// Intents sent and not yet settled, in send order.
    public private(set) var pending: [ServerIntent] = []
    /// The last refusal, cleared on the next send.
    public private(set) var lastReject: String?
    /// The display name of the last server this device approved.
    public private(set) var lastApproved: String?

    /// Client view state.
    public var approval = ServerApprovalDraft()

    private let source: any ServerSource

    public init(source: any ServerSource) {
        self.source = source
    }

    public func start() {
        source.start { [weak self] event in self?.handle(event) }
    }

    public func stop() {
        source.stop()
    }

    // MARK: - Derived state

    public var overall: ServerOverall {
        guard connection == .connected, let snapshot else { return .unavailable }
        guard snapshot.enabled else { return .off }
        switch snapshot.pairing {
        case .unpaired: return .unpaired
        case .pairing: return .pairing
        case .paired: break
        }
        if let worst = HealthOrdering.worst(snapshot.alerts), worst != .info { return .attention(worst) }
        return .serving
    }

    public var openAlerts: [HealthAlert] { HealthOrdering.open(snapshot?.alerts ?? []) }

    public var checklist: [HealthChecklistRow] {
        guard let snapshot else { return [] }
        return HealthOrdering.checklist(checks: snapshot.checks, alerts: snapshot.alerts)
    }

    public var timeline: [HealthAlert] { HealthOrdering.timeline(snapshot?.alerts ?? []) }

    public func isPending(_ match: (ServerIntentKind) -> Bool) -> Bool {
        pending.contains { match($0.kind) }
    }

    public func isFixing(_ check: HealthCheckID) -> Bool {
        isPending { $0 == .fixCheck(check) }
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
        guard connection == .connected else {
            lastReject = ServerStrings.unreachable
            return false
        }
        lastReject = nil
        let intent = ServerIntent(kind: kind)
        pending.append(intent)
        source.send(intent)
        return true
    }

    public func toggleServer() {
        guard let snapshot else { return }
        send(.setEnabled(!snapshot.enabled))
    }

    public func showPairingCode() { send(.showPairingCode) }
    public func fix(_ check: HealthCheckID) { send(.fixCheck(check)) }
    public func openHealth() { send(.openHealth) }
    public func revoke(device: String) { send(.revokeDevice(device)) }

    /// The code field changed: keep the edit form, and look the code up
    /// once it is complete.
    public func setApprovalCode(_ text: String) {
        let shown = PairingCode.editing(text)
        guard shown != approval.code else { return }
        approval.code = shown
        if candidate?.code != PairingCode.normalize(shown) { candidate = nil }
        if PairingCode.isComplete(shown) { send(.lookupCode(PairingCode.normalize(shown))) }
    }

    public func approve() {
        guard canApprove, let team = approval.team else { return }
        let name = approval.name.trimmingCharacters(in: .whitespacesAndNewlines)
        send(.approveCode(code: PairingCode.normalize(approval.code), team: team, name: name))
    }

    public func cancelApproval() {
        approval = ServerApprovalDraft()
        candidate = nil
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
            // A late reply for a code the user has since changed is stale.
            if let found, found.code != PairingCode.normalize(approval.code) { return }
            candidate = found
            guard let found else { return }
            if approval.team == nil || !found.teams.contains(where: { $0.id == approval.team }) {
                approval.team = found.teams.first?.id
            }
            if approval.name.isEmpty { approval.name = found.name }
        case let .settled(key, reject):
            let intent = pending.first { $0.key == key }
            pending.removeAll { $0.key == key }
            if let reject {
                lastReject = reject
            } else if case let .approveCode(_, _, name) = intent?.kind {
                lastApproved = name
                cancelApproval()
            }
        }
    }
}
