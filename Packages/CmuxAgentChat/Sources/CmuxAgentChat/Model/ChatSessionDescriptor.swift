import Foundation

/// Identity and live state of one chat-capable agent session.
///
/// Produced by the host (which discovers sessions via agent hook events and
/// transcript files) and consumed by chat surfaces for the session list and
/// the conversation header.
public struct ChatSessionDescriptor: Identifiable, Sendable, Equatable, Codable {
    /// The agent's own session identifier (hook `session_id`).
    public let id: String

    /// Which agent runtime owns the session.
    public let agentKind: ChatAgentKind

    /// Human-readable conversation title (typically the first user prompt,
    /// truncated by the producer).
    public let title: String?

    /// The cmux workspace the session's terminal belongs to, when known.
    public let workspaceID: String?

    /// The cmux terminal surface hosting the session, when known. Required
    /// for the send path (prompts are injected into this terminal).
    public let terminalID: String?

    /// The session's working directory, when known.
    public let workingDirectory: String?

    /// Live activity state.
    public let state: ChatAgentState

    /// Timestamp of the most recent transcript or hook activity.
    public let lastActivityAt: Date?

    /// Creates a session descriptor.
    ///
    /// - Parameters:
    ///   - id: The agent's own session identifier.
    ///   - agentKind: Which agent runtime owns the session.
    ///   - title: Human-readable conversation title.
    ///   - workspaceID: Owning cmux workspace when known.
    ///   - terminalID: Hosting cmux terminal surface when known.
    ///   - workingDirectory: Session working directory when known.
    ///   - state: Live activity state.
    ///   - lastActivityAt: Most recent activity timestamp.
    /// Orders a workspace's sessions for selection: the session most
    /// likely to want the user opens first, and a dead session never
    /// shadows a live one. Ended sessions appear only when every session
    /// is ended; within a state, most recent activity wins.
    ///
    /// - Parameter sessions: The workspace's sessions in any order.
    /// - Returns: The openable sessions, best first.
    public static func openable(_ sessions: [ChatSessionDescriptor]) -> [ChatSessionDescriptor] {
        let alive = sessions.filter { $0.state != .ended }
        let pool = alive.isEmpty ? sessions : alive
        return pool.sorted { lhs, rhs in
            let lp = selectionPriority(lhs.state)
            let rp = selectionPriority(rhs.state)
            if lp != rp { return lp < rp }
            return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
        }
    }

    /// Selection rank for a state; lower opens first.
    static func selectionPriority(_ state: ChatAgentState) -> Int {
        switch state {
        case .needsInput: return 0
        case .working: return 1
        case .idle: return 2
        case .ended: return 3
        }
    }

    public init(
        id: String,
        agentKind: ChatAgentKind,
        title: String? = nil,
        workspaceID: String? = nil,
        terminalID: String? = nil,
        workingDirectory: String? = nil,
        state: ChatAgentState = .idle,
        lastActivityAt: Date? = nil
    ) {
        self.id = id
        self.agentKind = agentKind
        self.title = title
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.workingDirectory = workingDirectory
        self.state = state
        self.lastActivityAt = lastActivityAt
    }

    private enum CodingKeys: String, CodingKey {
        case id = "session_id"
        case agentKind = "agent_kind"
        case title
        case workspaceID = "workspace_id"
        case terminalID = "terminal_id"
        case workingDirectory = "cwd"
        case state
        case lastActivityAt = "last_activity_at"
    }
}
