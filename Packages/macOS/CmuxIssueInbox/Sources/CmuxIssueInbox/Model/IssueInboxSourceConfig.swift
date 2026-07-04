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
    /// Workspace layout and command defaults used when spawning from this source.
    public var spawn: IssueInboxSpawnConfig?

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
    ///   - spawn: Workspace layout and command defaults used when spawning from this source.
    public init(
        type: IssueProviderKind,
        repo: String? = nil,
        teamKey: String? = nil,
        projectRoot: String? = nil,
        apiKeyEnvVar: String? = nil,
        spawn: IssueInboxSpawnConfig? = nil
    ) {
        self.type = type
        self.repo = repo
        self.teamKey = teamKey
        self.projectRoot = projectRoot
        self.apiKeyEnvVar = apiKeyEnvVar
        self.spawn = spawn
    }
}

/// Optional workspace setup configuration for an Issue Inbox source.
public struct IssueInboxSpawnConfig: Codable, Equatable, Sendable {
    /// Command to run in the dev server terminal pane.
    public var devServerCommand: String?
    /// Project website URL to open in the browser pane.
    public var webURL: String?
    /// Default agent used when no caller supplies one.
    public var defaultAgent: IssueSpawnAgent?
    /// Optional command template for agent startup.
    public var agentCommandTemplate: String?

    /// Creates workspace setup configuration.
    ///
    /// - Parameters:
    ///   - devServerCommand: Command to run in the dev server terminal pane.
    ///   - webURL: Project website URL to open in the browser pane.
    ///   - defaultAgent: Default agent used when no caller supplies one.
    ///   - agentCommandTemplate: Optional command template for agent startup.
    public init(
        devServerCommand: String? = nil,
        webURL: String? = nil,
        defaultAgent: IssueSpawnAgent? = nil,
        agentCommandTemplate: String? = nil
    ) {
        self.devServerCommand = devServerCommand
        self.webURL = webURL
        self.defaultAgent = defaultAgent
        self.agentCommandTemplate = agentCommandTemplate
    }
}

/// Supported Issue Inbox workspace spawn agent.
public enum IssueSpawnAgent: String, Codable, CaseIterable, Sendable {
    /// Start Claude with an issue prompt.
    case claude
    /// Start Codex with an issue prompt.
    case codex
    /// Start a plain shell.
    case none
}
