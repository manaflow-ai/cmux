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
    /// A frame with no session is a clear (release, session end, stop, tab
    /// gone); a new session on a held target is a takeover, so the target
    /// leaves its old session first.
    public mutating func leaseChanged(target: String, session: String?, wireState: String?) -> [Update] {
        let previous = byTarget[target]
        let affected = [previous?.session, session].compactMap { $0 }
        var before: [String: AgentCursorLeaseState?] = [:]
        for name in affected where before[name] == nil {
            before[name] = .some(effectiveState(of: name))
        }
        if let session {
            byTarget[target] = Held(session: session, state: Self.state(wire: wireState))
        } else {
            byTarget[target] = nil
        }
        var updates: [Update] = []
        var seen = Set<String>()
        for name in affected where seen.insert(name).inserted {
            let after = effectiveState(of: name)
            if before[name] ?? nil != after {
                updates.append(Update(session: name, state: after))
            }
        }
        return updates
    }

    /// Driving while any target drives; else paused or taken over; nil when
    /// the session holds nothing.
    private func effectiveState(of session: String) -> AgentCursorLeaseState? {
        let states = byTarget.values.filter { $0.session == session }.map(\.state)
        if states.isEmpty { return nil }
        if states.contains(.driving) { return .driving }
        if states.contains(.userDriving) { return .userDriving }
        return .paused
    }
}
