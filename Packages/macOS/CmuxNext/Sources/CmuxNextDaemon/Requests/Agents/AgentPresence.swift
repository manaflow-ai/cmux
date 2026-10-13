import Foundation

/// What the agent in one surface's terminal is touching right now: the
/// `agent-presence-changed` event (`agent-presence-v1`). The daemon reduces it
/// from the agent's hook tool calls; a nil `activity` clears it.
public struct AgentPresence: Sendable, Hashable, Decodable {
    public enum Activity: String, Sendable, Hashable, Decodable {
        case thinking, editing, reading, running, browsing, waiting
        case computerUse = "computer_use"
    }

    public var surface: SurfaceID
    /// Nil clears the surface's presence (turn or session end).
    public var activity: Activity?
    /// The adapter id (`claude`, `codex`, ...).
    public var agent: String?
    /// The agent's own session id, the stable key for its colour.
    public var session: String?
    public var tool: String?
    /// The file the current tool call targets, and its 1-based line.
    public var path: String?
    public var line: UInt64?
    public var updatedAtMs: UInt64?

    public init(surface: SurfaceID, activity: Activity?, agent: String? = nil, session: String? = nil,
                tool: String? = nil, path: String? = nil, line: UInt64? = nil, updatedAtMs: UInt64? = nil) {
        self.surface = surface
        self.activity = activity
        self.agent = agent
        self.session = session
        self.tool = tool
        self.path = path
        self.line = line
        self.updatedAtMs = updatedAtMs
    }

    enum CodingKeys: String, CodingKey {
        case surface, activity, agent, session, tool, path, line
        case updatedAtMs = "updated_at_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surface = try c.decode(SurfaceID.self, forKey: .surface)
        // An activity a newer daemon adds reads as thinking, not as a clear.
        activity = try c.decodeIfPresent(String.self, forKey: .activity).map { Activity(rawValue: $0) ?? .thinking }
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        line = try c.decodeIfPresent(UInt64.self, forKey: .line)
        updatedAtMs = try c.decodeIfPresent(UInt64.self, forKey: .updatedAtMs)
    }
}
