/// The identity fields read from one Claude automatic-team configuration.
struct ClaudeTeamConfiguration: Decodable {
    /// The team name Claude canonicalizes into its task-list directory.
    let name: String
    /// The main-thread agent identity Claude records for this team.
    let leadAgentId: String?
    /// The main-thread hook session identity Claude records for this team.
    let leadSessionId: String?
    /// The agents whose hook identities belong to the team.
    let members: [ClaudeTeamConfigurationMember]

    private enum CodingKeys: CodingKey {
        case name
        case leadAgentId
        case leadSessionId
        case members
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        leadAgentId = try container.decodeIfPresent(String.self, forKey: .leadAgentId)
        leadSessionId = try container.decodeIfPresent(String.self, forKey: .leadSessionId)
        members = try container.decodeIfPresent(
            [ClaudeTeamConfigurationMember].self,
            forKey: .members
        ) ?? []
    }
}
