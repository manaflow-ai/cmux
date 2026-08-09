import Foundation

/// A proven automatic-team identity for one Claude shared task list.
///
/// The leader is identified only when a hook omits `agent_id`. Hooks that carry
/// `agent_id` must match one of the exact agents recorded by the team config, so
/// an ordinary subagent sharing the leader's session cannot inherit the team.
public struct ClaudeTeamTaskListBinding: Codable, Equatable, Sendable {
    /// The Claude profile that owns the task list, or `nil` for a binding
    /// persisted by an earlier build before profile namespaces were recorded.
    public let taskStoreIdentity: ClaudeTaskStoreIdentity?
    /// The canonical direct-child name under Claude's task-store root.
    public let taskListID: String
    /// The team leader's exact hook session ID, when Claude recorded one.
    public let leaderSessionID: String?
    /// Exact hook agent IDs proven by the team configuration.
    public let agentIDs: [String]
    /// Bounded metadata generation that proved this identity unique.
    let teamConfigurationGeneration: String?

    private enum CodingKeys: CodingKey {
        case taskStoreIdentity
        case taskListID
        case leaderSessionID
        case agentIDs
        case teamConfigurationGeneration
    }

    /// Creates a canonical binding from one decoded team configuration.
    init?(
        taskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity? = nil,
        leaderSessionID: String?,
        agentIDs: [String],
        teamConfigurationGeneration: String? = nil
    ) {
        guard ClaudeTaskListDirectoryName(taskListID: taskListID)?.rawValue == taskListID else {
            return nil
        }
        let leaderSessionCandidate = leaderSessionID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedLeaderSessionID = leaderSessionCandidate?.isEmpty == false
            ? leaderSessionCandidate
            : nil
        let normalizedAgentIDs = Set(agentIDs.compactMap { agentID in
            let candidate = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? nil : candidate
        }).sorted()
        guard normalizedLeaderSessionID != nil || !normalizedAgentIDs.isEmpty else {
            return nil
        }
        self.taskStoreIdentity = taskStoreIdentity
        self.taskListID = taskListID
        self.leaderSessionID = normalizedLeaderSessionID
        self.agentIDs = normalizedAgentIDs
        self.teamConfigurationGeneration = teamConfigurationGeneration
    }

    /// Decodes and revalidates a persisted binding, rejecting invalid identities.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let validated = ClaudeTeamTaskListBinding(
            taskListID: try container.decode(String.self, forKey: .taskListID),
            taskStoreIdentity: try container.decodeIfPresent(
                ClaudeTaskStoreIdentity.self,
                forKey: .taskStoreIdentity
            ),
            leaderSessionID: try container.decodeIfPresent(
                String.self,
                forKey: .leaderSessionID
            ),
            agentIDs: try container.decodeIfPresent([String].self, forKey: .agentIDs) ?? [],
            teamConfigurationGeneration: try container.decodeIfPresent(
                String.self,
                forKey: .teamConfigurationGeneration
            )
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .taskListID,
                in: container,
                debugDescription: "Non-canonical or identity-less team task list binding"
            )
        }
        self = validated
    }

    /// Whether this proof owns a hook's exact team identity.
    ///
    /// `agentID` takes precedence over `sessionID`: Claude uses the leader's
    /// session ID for in-process subagent hooks, so matching both would let an
    /// unrelated subagent impersonate the leader.
    ///
    /// - Parameters:
    ///   - sessionID: The hook payload's exact `session_id` value.
    ///   - agentID: The hook payload's exact `agent_id`, when present.
    /// - Returns: `true` only when the strongest available identity was proven.
    public func matches(sessionID: String, agentID: String?) -> Bool {
        if let agentID = nonEmpty(agentID) {
            return agentIDs.contains(agentID)
        }
        guard let sessionID = nonEmpty(sessionID),
              let leaderSessionID else {
            return false
        }
        return sessionID == leaderSessionID
    }

    /// Copies an identity with the config generation that proved it unique.
    func withTeamConfigurationGeneration(_ teamConfigurationGeneration: String) -> Self {
        Self(
            validatedTaskListID: taskListID,
            taskStoreIdentity: taskStoreIdentity,
            leaderSessionID: leaderSessionID,
            agentIDs: agentIDs,
            teamConfigurationGeneration: teamConfigurationGeneration
        )
    }

    private init(
        validatedTaskListID: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity?,
        leaderSessionID: String?,
        agentIDs: [String],
        teamConfigurationGeneration: String?
    ) {
        self.taskStoreIdentity = taskStoreIdentity
        taskListID = validatedTaskListID
        self.leaderSessionID = leaderSessionID
        self.agentIDs = agentIDs
        self.teamConfigurationGeneration = teamConfigurationGeneration
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
