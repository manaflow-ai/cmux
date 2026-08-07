/// One agent membership read from a Claude automatic-team configuration.
struct ClaudeTeamConfigurationMember: Decodable {
    /// The exact hook `agent_id` associated with the member.
    let agentId: String
}
