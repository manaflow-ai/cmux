import Foundation

public enum AgentState: String, Sendable, Hashable, Codable {
    case working, blocked, idle, done, unknown
}

public struct AgentStatus: Sendable, Hashable, Decodable {
    public var surface: SurfaceID
    public var state: AgentState
    public var source: String?
    public var session: String?
    public var agent: String?
    /// The harness's own session id a hook reported (`agent_session_id`): hook reports publish no
    /// `session`, so this is how a `cmux://agent` link finds the terminal. Nil from an older daemon.
    public var agentSessionID: String?
    public var updatedAtMs: UInt64
    /// When the agent entered `state` (Unix ms, `since_ms`); nil from an older daemon, whose
    /// `updatedAtMs` moves with every report and says nothing about how long a state held.
    public var sinceMs: UInt64?
    /// The agent's last prompt (at most 200 characters, `last_prompt`): the daemon keeps it in
    /// memory only; nil before one or from an older daemon.
    public var lastPrompt: String?

    public init(surface: SurfaceID, state: AgentState, source: String? = nil, session: String? = nil, agent: String? = nil,
                agentSessionID: String? = nil, updatedAtMs: UInt64 = 0, sinceMs: UInt64? = nil,
                lastPrompt: String? = nil) {
        self.surface = surface
        self.state = state
        self.source = source
        self.session = session
        self.agent = agent
        self.agentSessionID = agentSessionID
        self.updatedAtMs = updatedAtMs
        self.sinceMs = sinceMs
        self.lastPrompt = lastPrompt
    }

    enum CodingKeys: String, CodingKey {
        case surface, state, source, session, agent
        case agentSessionID = "agent_session_id"
        case updatedAtMs = "updated_at_ms"
        case sinceMs = "since_ms"
        case lastPrompt = "last_prompt"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surface = try c.decode(SurfaceID.self, forKey: .surface)
        state = (try? c.decode(AgentState.self, forKey: .state)) ?? .unknown
        source = try c.decodeIfPresent(String.self, forKey: .source)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        agentSessionID = (try? c.decodeIfPresent(String.self, forKey: .agentSessionID)).flatMap { $0.isEmpty ? nil : $0 }
        updatedAtMs = try c.decodeIfPresent(UInt64.self, forKey: .updatedAtMs) ?? 0
        sinceMs = try? c.decodeIfPresent(UInt64.self, forKey: .sinceMs)
        lastPrompt = (try? c.decodeIfPresent(String.self, forKey: .lastPrompt)).flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension AgentStatus {
    /// The harness session this agent runs (`claude`, `codex` session id): a hook report's
    /// `agentSessionID`, else a direct report's `session`. Hook bookkeeping markers
    /// (`cmux-hook-…`) are none. Copy Session ID and `cmux://agent` links read it.
    public var harnessSessionID: String? {
        guard let id = agentSessionID ?? session, !id.isEmpty, !id.hasPrefix("cmux-hook-") else { return nil }
        return id
    }
}

public struct ListAgentsRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var agents: [AgentStatus]
    }
    public static let command = "list-agents"
    public var surface: SurfaceID?
    public var state: AgentState?
    public init(surface: SurfaceID? = nil, state: AgentState? = nil) {
        self.surface = surface
        self.state = state
    }
}

