public import Foundation

/// The owner side of a hand-off's turns (cloud work mode; `backend/apps/api/src/handoffs/routes.ts`):
/// before a prompt that starts a turn goes to a chat on a Cloud machine, the app opens that turn. The
/// session's hand-off is made at its first turn (`POST /v1/handoffs`, one per session: the same
/// request again answers the hand-off as it is), and each later turn begins once the last one ended
/// (`POST /v1/handoffs/:id/turns {after}`). The prompt then names the turn (`handoff-<turn>-<id>`),
/// and acpmux on the machine reports it (cmux-tui acpmux `daemon/cloud_handoff.rs`).
extension CloudOwnerAPIClient {
    /// `POST /v1/handoffs {sessionId, machine}`: the session's hand-off, made now or as it already
    /// is. The answer's machine token is the machine's credential: it is never read here, kept or
    /// logged (the machine reports as its own VM install).
    public func handoffOpen(session: String, machine: String) async throws -> CloudHandoffTurn {
        try await handoffPost("owner.handoff_open", ["session": session, "machine": machine])
    }

    /// `POST /v1/handoffs/:id/turns {after}`: begins turn `after + 1` (a repeat answers the same turn).
    public func handoffBeginTurn(_ id: String, after: Int) async throws -> CloudHandoffTurn {
        try await handoffPost("owner.handoff_begin_turn", ["id": id, "after": max(0, after)])
    }

    /// A POST to the hand-off routes: the `{handoff}` of a 2xx answer, or of a refusal that carries
    /// it (`handoff.conflict`, `handoff.turn_conflict`, `handoff.turn_running`, `handoff.closed`), as
    /// ``CloudHandoffTurn/refusal``. Any other answer throws. The daemon reads only the turn's
    /// fields: the machine token the answer carries never reaches the app.
    func handoffPost(_ name: String, _ args: [String: any Sendable]) async throws -> CloudHandoffTurn {
        let data = try await call(name, args, wait: .seconds(20))
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], var turn = CloudHandoffTurn(json: object) else {
            throw CloudAPIError.decoding("\(name): not a hand-off")
        }
        turn.refusal = object["refusal"] as? String
        return turn
    }
}

/// A hand-off as its turns need it: which turn is current, and how it stands.
public nonisolated struct CloudHandoffTurn: Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var machine: String
    /// The current turn, from 1.
    public var turn: Int
    /// `open` or `closed`.
    public var state: String
    /// The current turn's status: `starting`, `running`, `needs-you`, `done`, `failed` or `cancelled`.
    public var status: String
    /// The store's refusal that carried this view (`handoff.turn_running`, …); nil for a 2xx answer.
    public var refusal: String?

    public init(id: String, sessionId: String, machine: String, turn: Int, state: String, status: String, refusal: String? = nil) {
        (self.id, self.sessionId, self.machine, self.turn, self.state, self.status, self.refusal) = (id, sessionId, machine, turn, state, status, refusal)
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, CloudOwnerAPIClient.isHandoffID(id), let sessionId = json["sessionId"] as? String,
              let machine = json["machine"] as? String, let turn = json["turn"] as? Int, turn >= 1,
              let state = json["state"] as? String, state == "open" || state == "closed",
              let status = json["status"] as? String, CloudHandoff.statuses.contains(status) else { return nil }
        self.init(id: id, sessionId: sessionId, machine: machine, turn: turn, state: state, status: status)
    }

    /// What a prompt that starts a turn does with this hand-off: name its current turn (made or
    /// begun, and not run yet), begin the next one (the current one ended), or name none (a turn
    /// runs or waits for the person, or the hand-off is closed).
    public var next: Next {
        guard state == "open" else { return .none }
        if status == "starting" { return .name(turn) }
        return CloudHandoff.turnEnds.contains(status) ? .begin(after: turn) : .none
    }

    public enum Next: Equatable, Sendable {
        case name(Int)
        case begin(after: Int)
        case none
    }
}
