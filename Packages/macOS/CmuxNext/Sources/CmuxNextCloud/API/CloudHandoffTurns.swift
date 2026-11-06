public import Foundation

/// The owner side of a hand-off's turns (cloud work mode; `backend/apps/api/src/handoffs/routes.ts`):
/// before a prompt that starts a turn goes to a chat on a Cloud machine, the app opens that turn. The
/// session's hand-off is made at its first turn (`POST /v1/handoffs`, one per session: the same
/// request again answers the hand-off as it is), and each later turn begins once the last one ended
/// (`POST /v1/handoffs/:id/turns {after}`). The prompt then names the turn (`handoff-<turn>-<id>`),
/// and acpmux on the machine reports it (cmux-tui acpmux `daemon/cloud_handoff.rs`). The calls, their
/// id checks and the answer's reading are cmux-tui's (`cli/cloud_api/owner.rs`).
extension CloudOwnerAPIClient {
    /// `POST /v1/handoffs {sessionId, machine}`: the session's hand-off, made now or as it already
    /// is. The answer's machine token is the machine's credential: cmux-tui never reads it into the
    /// answer, so it is never kept or logged here.
    public func handoffOpen(session: String, machine: String) async throws -> CloudHandoffTurn {
        try await call("owner.handoff_open", ["session": session, "machine": machine], timeout: .seconds(20), as: CloudHandoffTurn.self)
    }

    /// `POST /v1/handoffs/:id/turns {after}`: begins turn `after + 1` (a repeat answers the same turn).
    public func handoffBeginTurn(_ id: String, after: Int) async throws -> CloudHandoffTurn {
        try await call("owner.handoff_begin_turn", ["id": id, "after": after], timeout: .seconds(20), as: CloudHandoffTurn.self)
    }
}

/// A hand-off as its turns need it: which turn is current, and how it stands. A 2xx answer, or a
/// refusal that answers the hand-off as it is (`handoff.conflict`, `handoff.turn_conflict`,
/// `handoff.turn_running`, `handoff.closed`, in ``refusal``).
public nonisolated struct CloudHandoffTurn: Equatable, Sendable, Decodable {
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

    /// What a prompt that starts a turn does with this hand-off: name its current turn (made or
    /// begun, and not run yet), begin the next one (the current one ended), or name none (a turn
    /// runs or waits for the person, or the hand-off is closed).
    public var next: Next {
        guard state == "open" else { return .none }
        if status == "starting" { return .name(turn) }
        return ["done", "failed", "cancelled"].contains(status) ? .begin(after: turn) : .none
    }

    public enum Next: Equatable, Sendable {
        case name(Int)
        case begin(after: Int)
        case none
    }
}
