/// Versioned semantic state attached to one remote workspace-list entry.
public struct MobileWorkspaceRemoteState: Decodable, Sendable, Equatable {
    /// The schema version of this nested state object.
    public let version: Int
    /// Agent lifecycles aggregated by agent identifier.
    public let agents: [MobileWorkspaceAgentStatus]
    /// Git state, when the host has observed a repository.
    public let git: MobileWorkspaceGitState?
    /// The first pull request in the host sidebar's spatial display order.
    public let pullRequest: MobileWorkspacePullRequestState?
    /// Notification and unread state for the workspace.
    public let notifications: MobileWorkspaceNotificationState

    private enum CodingKeys: String, CodingKey {
        case version
        case agents
        case git
        case pullRequest = "pull_request"
        case notifications
    }

    /// Decodes versioned workspace state, accepting a host that omits agent detail.
    /// - Parameter decoder: The decoder for the remote-state object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        agents = try container.decodeIfPresent([MobileWorkspaceAgentStatus].self, forKey: .agents) ?? []
        git = try container.decodeIfPresent(MobileWorkspaceGitState.self, forKey: .git)
        pullRequest = try container.decodeIfPresent(MobileWorkspacePullRequestState.self, forKey: .pullRequest)
        notifications = try container.decode(MobileWorkspaceNotificationState.self, forKey: .notifications)
    }
}
