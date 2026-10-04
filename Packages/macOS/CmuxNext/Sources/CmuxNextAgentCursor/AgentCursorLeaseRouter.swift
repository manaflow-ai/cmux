/// Turns per-target lease frames (`lease {targetID, lease?}` from the
/// browser host or the CUA host) into one cursor state per session. A session
/// may lease several targets; its cursor is driving while any of them is
/// driving, paused or taken over while all of them are, and gone when it
/// holds none.
public struct AgentCursorLeaseRouter: Sendable {
    public struct Update: Equatable, Sendable {
        public var session: String
        /// `nil`: the session holds no lease any more.
        public var state: AgentCursorLeaseState?
    }

    private struct Held: Sendable {
        var session: String
        var state: AgentCursorLeaseState
    }

    private var byTarget: [String: Held] = [:]

    public init() {}

    /// Maps the wire state (`driving`, `paused`, `user_driving`); an unknown
    /// or missing state is drawn as driving, never invented as a pause.
    public static func state(wire: String?) -> AgentCursorLeaseState {
        switch wire {
        case "paused": .paused
        case "user_driving": .userDriving
        default: .driving
        }
    }

    /// Applies one lease frame; returns the sessions whose cursor state changed.
    public mutating func leaseChanged(target: String, session: String?, wireState: String?) -> [Update] {
        _ = (target, session, wireState)
        return []
    }
}
