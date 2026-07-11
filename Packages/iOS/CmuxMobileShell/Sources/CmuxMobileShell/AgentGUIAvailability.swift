public import CmuxAgentReplica

public struct AgentGUIAvailability: Equatable, Sendable {
    public let sessionID: AgentSessionID
    public let kind: AgentKind

    public static func derive(
        sessions: [AgentSessionSnapshot],
        selectedTerminalID: String?
    ) -> AgentGUIAvailability? {
        guard let selectedTerminalID else { return nil }
        guard let session = sessions
            .filter({ $0.surfaceID == selectedTerminalID && $0.phase.offersAgentGUI })
            .max(by: Self.isOlderSession)
        else {
            return nil
        }
        return AgentGUIAvailability(sessionID: session.id, kind: session.kind)
    }

    private static func isOlderSession(
        _ lhs: AgentSessionSnapshot,
        than rhs: AgentSessionSnapshot
    ) -> Bool {
        if lhs.lastActivityHint != rhs.lastActivityHint {
            return lhs.lastActivityHint < rhs.lastActivityHint
        }
        return lhs.id.rawValue > rhs.id.rawValue
    }
}

extension SessionPhase {
    /// Ended is the only terminal session phase currently defined by the replica model.
    var offersAgentGUI: Bool {
        switch self {
        case .starting, .idle, .working, .needsInput, .unknown:
            true
        case .ended:
            false
        }
    }
}
