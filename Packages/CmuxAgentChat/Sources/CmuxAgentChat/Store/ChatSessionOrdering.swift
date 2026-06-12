import Foundation

/// Orders a workspace's chat sessions for selection: the session most
/// likely to want the user opens first, and a dead session never shadows
/// a live one.
///
/// Lives in the domain package (not the view) so the rule is unit-tested
/// independently of SwiftUI.
public enum ChatSessionOrdering {
    /// Sessions worth opening, attention first.
    ///
    /// Ended sessions are included only when every session is ended;
    /// otherwise they are dropped so a stale "Session ended" can't be
    /// picked over a running agent. Within a state, most recent first.
    ///
    /// - Parameter sessions: The workspace's sessions in any order.
    /// - Returns: The openable sessions, best first.
    public static func openable(_ sessions: [ChatSessionDescriptor]) -> [ChatSessionDescriptor] {
        let alive = sessions.filter { $0.state != .ended }
        let pool = alive.isEmpty ? sessions : alive
        return pool.sorted { lhs, rhs in
            let lp = priority(lhs.state)
            let rp = priority(rhs.state)
            if lp != rp { return lp < rp }
            return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
        }
    }

    /// Selection rank for a state; lower opens first.
    static func priority(_ state: ChatAgentState) -> Int {
        switch state {
        case .needsInput: return 0
        case .working: return 1
        case .idle: return 2
        case .ended: return 3
        }
    }
}
