/// One agent's aggregated state within a remote workspace.
public struct MobileWorkspaceAgentStatus: Decodable, Sendable, Equatable {
    /// The host's stable agent identifier, such as `claude_code` or `codex`.
    public let agent: String
    /// The most important lifecycle currently reported for the agent.
    public let state: MobileWorkspaceAgentLifecycle
    /// Panel identifiers contributing to the aggregated lifecycle.
    public let panelIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case agent
        case state
        case panelIDs = "panel_ids"
    }

    /// Decodes an agent status, accepting hosts that omit the optional panel detail.
    /// - Parameter decoder: The decoder for the agent-status object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(String.self, forKey: .agent)
        state = try container.decode(MobileWorkspaceAgentLifecycle.self, forKey: .state)
        panelIDs = try container.decodeIfPresent([String].self, forKey: .panelIDs) ?? []
    }
}
