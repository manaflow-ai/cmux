public import Foundation

/// Where one of the Chief's agents runs now, followed by its acpmux session id
/// (plans/cmux-next/home-agent-pills-DESIGN.md, Identity).
///
/// The session id never changes when the agent moves; its place does, and each move raises a counter in
/// one write with the new place: the Chief's spawn record (`host/spawns`: `place`, `epoch`, a Chief move
/// that hands its agents over) and acpmux's session (`movedTo`, `moveEpoch`, `acpmux session move`).
/// Home keeps the ref it saw last and re-attaches only when a counter is higher (``follow(_:)``), so an
/// older read never moves an open tab back.
///
/// ```swift
/// var ref = HomeAgentSessionRef(peer: "a963", session: "s-81")
/// ref.follow(HomeAgentSessionRef(peer: "a963", session: "s-81", place: "cmux-mini", moveEpoch: 1)) // true
/// ref.place      // "cmux-mini"
/// ref.sessionLink // cmux://session/s-81, where acpmux resolves the session now
/// ```
public struct HomeAgentSessionRef: Hashable, Sendable {
    /// The agent's id in the Chief's chat (`a963`).
    public var peer: String
    /// Its acpmux session id, the same on every machine it moves to.
    public var session: String
    /// The machine it runs on now (an acpmux peer name, or a Cloud place); nil: where the Chief's own
    /// acpmux runs.
    public var place: String?
    /// The Chief's spawn record's epoch: raised by every Chief move that hands the agent over.
    public var spawnEpoch: UInt64
    /// acpmux's `moveEpoch` of the session: raised by every `acpmux session move`.
    public var moveEpoch: UInt64

    /// - Parameters:
    ///   - peer: The agent's id.
    ///   - session: Its acpmux session id.
    ///   - place: Where it runs now; nil: the Chief's own acpmux.
    ///   - spawnEpoch: The spawn record's epoch (0: never handed over).
    ///   - moveEpoch: acpmux's move epoch (0: never moved).
    public init(peer: String, session: String, place: String? = nil, spawnEpoch: UInt64 = 0, moveEpoch: UInt64 = 0) {
        self.peer = peer
        self.session = session
        self.place = place
        self.spawnEpoch = spawnEpoch
        self.moveEpoch = moveEpoch
    }

    /// True once the agent moved away from the Chief's own acpmux at least once.
    public var hasMoved: Bool { spawnEpoch > 0 || moveEpoch > 0 }

    /// The session's link (`cmux://session/<id>`): the app opens the session where acpmux has it now.
    public var sessionLink: URL? { URL(string: "cmux://session/\(session)") }

    /// Takes `seen` when it is the same session with a higher counter: the agent moved, so its place is
    /// `seen`'s. An equal or older read changes nothing.
    ///
    /// - Parameter seen: A newer read of the agent's session.
    /// - Returns: True when the ref re-attached at a new place.
    @discardableResult
    public mutating func follow(_ seen: HomeAgentSessionRef) -> Bool {
        guard seen.session == session, seen.spawnEpoch > spawnEpoch || seen.moveEpoch > moveEpoch else { return false }
        place = seen.place
        spawnEpoch = max(spawnEpoch, seen.spawnEpoch)
        moveEpoch = max(moveEpoch, seen.moveEpoch)
        return true
    }
}
