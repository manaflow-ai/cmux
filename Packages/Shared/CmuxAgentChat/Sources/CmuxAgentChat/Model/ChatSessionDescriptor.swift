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

    /// Whether this is an agent conversation or a plain-terminal command
    /// log. Defaults to `.agent`; a declaration default (not a CodingKey)
    /// keeps existing wire payloads decoding while Slice D adds the wire
    /// field for real terminal sessions.
    public var kind: ChatSessionKind = .agent

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

    /// Monotonic per-session revision, bumped by the host on every change to
    /// this session. The client reconciles best-effort pushes against
    /// authoritative pulls by this number: apply a push only when its version
    /// is strictly greater than the last applied, and replace wholesale from a
    /// snapshot pull. A missed or duplicated push self-heals on the next pull.
    public var version: Int = 0

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
        kind: ChatSessionKind = .agent,
        title: String? = nil,
        workspaceID: String? = nil,
        terminalID: String? = nil,
        workingDirectory: String? = nil,
        state: ChatAgentState = .idle,
        lastActivityAt: Date? = nil,
        version: Int = 0
    ) {
        self.id = id
        self.agentKind = agentKind
        self.kind = kind
        self.title = title
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.workingDirectory = workingDirectory
        self.state = state
        self.lastActivityAt = lastActivityAt
        self.version = version
    }

    /// A copy with a new live state, leaving identity and bindings intact.
    /// Used by the session-list reducer to apply a `stateChanged` push
    /// without a full descriptor round-trip.
    ///
    /// - Parameter newState: The state to set.
    /// - Returns: The updated descriptor.
    public func withState(_ newState: ChatAgentState) -> ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: id,
            agentKind: agentKind,
            kind: kind,
            title: title,
            workspaceID: workspaceID,
            terminalID: terminalID,
            workingDirectory: workingDirectory,
            state: newState,
            lastActivityAt: lastActivityAt,
            version: version
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id = "session_id"
        case agentKind = "agent_kind"
        case kind
        case title
        case workspaceID = "workspace_id"
        case terminalID = "terminal_id"
        case workingDirectory = "cwd"
        case state
        case lastActivityAt = "last_activity_at"
        case version
    }

    // Custom Codable so `kind` decodes with a `.agent` default when absent
    // (older payloads predate it), while still travelling on the wire for
    // terminal sessions.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agentKind = try container.decode(ChatAgentKind.self, forKey: .agentKind)
        kind = try container.decodeIfPresent(ChatSessionKind.self, forKey: .kind) ?? .agent
        title = try container.decodeIfPresent(String.self, forKey: .title)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        terminalID = try container.decodeIfPresent(String.self, forKey: .terminalID)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        state = try container.decode(ChatAgentState.self, forKey: .state)
        lastActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(agentKind, forKey: .agentKind)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try container.encodeIfPresent(terminalID, forKey: .terminalID)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(lastActivityAt, forKey: .lastActivityAt)
        try container.encode(version, forKey: .version)
    }
}
