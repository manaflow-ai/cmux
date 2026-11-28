import Foundation

/// Where a new agent chat of a workspace starts (`workspace.agent_start.get`, capability
/// `workspace-agent-start-v1`, cx-9aps): the store's one answer. The app shows it and starts the
/// chat there; it never decides the folder itself.
public struct AgentStartAnswer: Decodable, Sendable, Equatable {
    /// Which rule gave the folder: `seed` (the proposed cwd), `chosen` (the workspace's agent
    /// folder), `workspace` (a terminal tab's folder) or `agent_home` (the private folder).
    public var kind: String
    /// The folder, canonical; nil only for `agent_home` when the workspace id names no folder.
    public var cwd: String?
    /// The workspace's agent-home folder.
    public var agentHome: String?
    /// The proposed cwd when it was not used, and why (`home`, `above_home`, `agent_home`,
    /// `missing`).
    public var skipped: Skipped?

    public struct Skipped: Decodable, Sendable, Equatable {
        public var cwd: String
        public var reason: String
    }

    enum CodingKeys: String, CodingKey {
        case kind, cwd, skipped
        case agentHome = "agent_home"
    }

    public init(kind: String, cwd: String?, agentHome: String?, skipped: Skipped? = nil) {
        self.kind = kind
        self.cwd = cwd
        self.agentHome = agentHome
        self.skipped = skipped
    }
}

extension StateResourceClient {
    /// `workspace.agent_start.get {workspace, cwd?}`: a read, no idempotency key.
    public func agentStart(_ workspace: ResourceID, cwd: String?) async throws -> AgentStartAnswer {
        var fields: [String: JSONValue] = ["workspace": .string(workspace.rawValue)]
        if let cwd { fields["cwd"] = .string(cwd) }
        let params = fields
        return try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "workspace.agent_start.get", params: params, idempotencyKey: nil)
        }, as: AgentStartAnswer.self)
    }
}
