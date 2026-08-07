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
}
