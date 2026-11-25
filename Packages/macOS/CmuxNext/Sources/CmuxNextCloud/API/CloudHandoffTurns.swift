public import Foundation

/// The owner side of a hand-off's turns (cloud work mode; `backend/apps/api/src/handoffs/routes.ts`):
/// before a prompt that starts a turn goes to a chat on a Cloud machine, the app opens that turn. The
/// session's hand-off is made at its first turn (`POST /v1/handoffs`, one per session: the same
/// request again answers the hand-off as it is), and each later turn begins once the last one ended
/// (`POST /v1/handoffs/:id/turns {after}`), each the daemon's `cloud.owner.*`. The prompt then names the turn (`handoff-<turn>-<id>`),
/// and acpmux on the machine reports it (cmux-tui acpmux `daemon/cloud_handoff.rs`).
extension CloudOwnerAPIClient {
    /// `cloud.owner.handoff_open` (`POST /v1/handoffs {sessionId, machine}`): the session's hand-off, made now or as it
    /// already is. The answer's machine token is the machine's credential: Rust never reads it into the answer.
    public func handoffOpen(session: String, machine: String) async throws -> CloudHandoffTurn {
        try await handoffPost("owner.handoff_open", ["session": session, "machine": machine])
    }

    /// `cloud.owner.handoff_begin_turn` (`POST /v1/handoffs/:id/turns {after}`): begins turn `after + 1` (a repeat
    /// answers the same turn).
    public func handoffBeginTurn(_ id: String, after: Int) async throws -> CloudHandoffTurn {
        try await handoffPost("owner.handoff_begin_turn", ["id": id, "after": max(0, after)])
    }

    /// A hand-off route's turn (20 s), Rust's reading of it (cmux-cloud-api `owner::handoff_post`): the `{handoff}` of a
    /// 2xx answer, or of a refusal that carries it (`handoff.conflict`, `handoff.turn_conflict`, `handoff.turn_running`,
    /// `handoff.closed`) with that code as ``CloudHandoffTurn/refusal``. Any other answer throws.
    func handoffPost(_ call: String, _ args: [String: any Sendable]) async throws -> CloudHandoffTurn {
        let data = try await daemon(call, args, timeout: Self.bound(.seconds(20)))
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var turn = CloudHandoffTurn(json: object) else { throw CloudAPIError.decoding("cloud.\(call): not a hand-off") }
        turn.refusal = (object["refusal"] as? String).flatMap { CloudHandoffTurn.refusals.contains($0) ? $0 : nil }
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

    /// The refusals that answer the hand-off as it is.
    static let refusals: Set<String> = ["handoff.conflict", "handoff.turn_conflict", "handoff.turn_running", "handoff.closed"]

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

/// What a prompt of a Cloud chat names (the App's `CloudHandoffTurnOpener`).
extension CloudHandoffTurn {
    /// What ``open(session:machine:client:)`` found: the turn a prompt names, or why none.
    public enum Opened: Equatable, Sendable {
        case turn(id: String, number: Int)
        /// `handoff.conflict` (the session's hand-off is on another machine), `handoff.closed`,
        /// `handoff.turn_running` (a turn runs or waits for the person) or `handoff.turn_conflict`
        /// (other devices kept beginning turns).
        case refused(String)
    }

    /// The turn a prompt of `session` on `machine` names: the session's hand-off is made or read, then
    /// its current turn is named when it has not run yet, or the next one begins once it ended.
    public static func open(session: String, machine: String, client: CloudOwnerAPIClient) async throws -> Opened {
        try await open(session: session, machine: machine,
                       make: { try await client.handoffOpen(session: $0, machine: $1) },
                       begin: { try await client.handoffBeginTurn($0, after: $1) })
    }

    /// ``open(session:machine:client:)`` over its two calls (tests stand in for the store).
    public static func open(session: String, machine: String,
                     make: (String, String) async throws -> CloudHandoffTurn,
                     begin: (String, Int) async throws -> CloudHandoffTurn) async throws -> Opened {
        var handoff = try await make(session, machine)
        // One hand-off per session, made with this machine: one on another machine (a chat moved
        // since) is not this chat's turn to name.
        guard handoff.sessionId == session, handoff.machine == machine, handoff.refusal != "handoff.conflict" else {
            return .refused("handoff.conflict")
        }
        // Another device may begin (and even finish) the next turn first (`turn_conflict` answers
        // the hand-off as it is): its turn is named while it has not run yet, and one that already
        // ended begins the one after. A few tries, then the prompt goes unnamed.
        for _ in 0..<3 {
            switch handoff.next {
            case .name(let turn): return .turn(id: handoff.id, number: turn)
            case .none: return .refused(handoff.state == "closed" ? "handoff.closed" : "handoff.turn_running")
            case .begin(let after):
                let begun = try await begin(handoff.id, after)
                // The store may close the hand-off after the create but before this POST. Its
                // refusal carries the current hand-off (whose turn still equals `after`), so
                // preserve that authoritative code before validating the normal success shape.
                if begun.state == "closed" { return .refused("handoff.closed") }
                if let refusal = begun.refusal, refusal != "handoff.turn_conflict" { return .refused(refusal) }
                guard begun.id == handoff.id, begun.sessionId == session, begun.machine == machine, begun.turn > after else {
                    return .refused("handoff.turn_conflict")
                }
                handoff = begun
            }
        }
        // The last begin's answer is read too: a turn it made is named, never left unreported.
        if case .name(let turn) = handoff.next { return .turn(id: handoff.id, number: turn) }
        return .refused("handoff.turn_conflict")
    }
}
