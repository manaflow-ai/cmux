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
    public var updatedAtMs: UInt64

    public init(surface: SurfaceID, state: AgentState, source: String? = nil, session: String? = nil, agent: String? = nil, updatedAtMs: UInt64 = 0) {
        self.surface = surface
        self.state = state
        self.source = source
        self.session = session
        self.agent = agent
        self.updatedAtMs = updatedAtMs
    }

    enum CodingKeys: String, CodingKey {
        case surface, state, source, session, agent
        case updatedAtMs = "updated_at_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surface = try c.decode(SurfaceID.self, forKey: .surface)
        state = (try? c.decode(AgentState.self, forKey: .state)) ?? .unknown
        source = try c.decodeIfPresent(String.self, forKey: .source)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        updatedAtMs = try c.decodeIfPresent(UInt64.self, forKey: .updatedAtMs) ?? 0
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

