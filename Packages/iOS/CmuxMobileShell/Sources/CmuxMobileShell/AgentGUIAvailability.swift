public import CmuxAgentReplica

public struct AgentGUIAvailability: Equatable, Sendable {
    public let sessionID: AgentSessionID
    public let kind: AgentKind

    /// Whether the current Agent GUI is exposed through the shipping mobile UI.
    ///
    /// The implementation remains compiled and testable while its replacement is
    /// designed, but no current app surface may make it user-accessible.
    public static let isUserInterfaceExposed = false

    /// Resolves availability for a user-facing app surface.
    ///
    /// This is the single product exposure boundary. ``derive(sessions:selectedTerminalID:)``
    /// remains available to exercise the retained implementation independently.
    /// - Parameters:
    ///   - sessions: Agent sessions known to the current Mac connection.
    ///   - selectedTerminalID: The terminal currently shown in the workspace.
    /// - Returns: A matching session only when the product UI is exposed.
    public static func deriveForUserInterface(
        sessions: [AgentSessionSnapshot],
        selectedTerminalID: String?
    ) -> AgentGUIAvailability? {
        guard isUserInterfaceExposed else { return nil }
        return derive(sessions: sessions, selectedTerminalID: selectedTerminalID)
    }

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
