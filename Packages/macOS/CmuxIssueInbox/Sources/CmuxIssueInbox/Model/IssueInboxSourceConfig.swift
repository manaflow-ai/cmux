public import Foundation

/// One configured issue source from `~/.config/cmux/issue-inbox.json`.
public struct IssueInboxSourceConfig: Codable, Equatable, Sendable, Identifiable {
    /// Provider type for this source.
    public var type: IssueProviderKind
    /// GitHub `owner/repo` for GitHub sources.
    public var repo: String?
    /// Linear team key for Linear sources.
    public var teamKey: String?
    /// Local project root used by workspace spawn.
    public var projectRoot: String?
    /// Environment variable holding the Linear API key.
    public var apiKeyEnvVar: String?

    /// Stable source identifier.
    public var id: String { sourceID }

    /// Stable source identifier used for cache and error isolation.
    public var sourceID: String {
        switch type {
        case .github:
            return "github:\(repo ?? "")"
        case .linear:
            return "linear:\(teamKey ?? "")"
        }
    }

    /// Human-readable source label.
    public var displayName: String {
        switch type {
        case .github:
            return repo ?? "GitHub"
        case .linear:
            return teamKey.map { "Linear \($0)" } ?? "Linear"
        }
    }

    /// Creates a source configuration.
    ///
    /// - Parameters:
    ///   - type: Provider type.
    ///   - repo: GitHub `owner/repo`, required for GitHub sources.
    ///   - teamKey: Linear team key, required for Linear sources.
    ///   - projectRoot: Local project root used by workspace spawn.
    ///   - apiKeyEnvVar: Environment variable holding the Linear API key.
    public init(
        type: IssueProviderKind,
        repo: String? = nil,
        teamKey: String? = nil,
        projectRoot: String? = nil,
        apiKeyEnvVar: String? = nil
    ) {
        self.type = type
        self.repo = repo
        self.teamKey = teamKey
        self.projectRoot = projectRoot
        self.apiKeyEnvVar = apiKeyEnvVar
    }
}
