public import CmuxNextActions
public import CmuxNextCloud
import Foundation

/// The new chat folder picker's GitHub section: `github.status {}`, `github.connect {}` and
/// `github.repos.list {query?}` (``AgentPaneGitHub`` answers them). The section lists the person's
/// repositories the cmux GitHub App reaches; a chat started in one is a Cloud chat in its clone
/// (`github:owner/name`, ``AgentPaneGitHubFolder``).
public nonisolated enum AgentPaneGitHubRequest: Equatable, Sendable {
    case status
    case connect
    case repos(query: String?)

    public static let methods: Set<String> = ["github.status", "github.connect", "github.repos.list"]

    /// The page's params, checked; nil for anything else. `query` is the picker's search text, or null.
    init?(method: String, params: [String: Any]?) {
        switch method {
        case "github.status": self = .status
        case "github.connect": self = .connect
        case "github.repos.list":
            let query = params?["query"]
            if query == nil || query is NSNull {
                self = .repos(query: nil)
            } else if let text = query as? String, text.utf8.count <= 1024, !text.contains("\0") {
                self = .repos(query: text)
            } else {
                return nil
            }
        default: return nil
        }
    }

    public var method: String {
        switch self {
        case .status: "github.status"
        case .connect: "github.connect"
        case .repos: "github.repos.list"
        }
    }

    /// The reply. Connect opens the person's browser, so only on their own click (`gesture`).
    @MainActor func reply(_ gitHub: AgentPaneGitHub?, gesture: () -> Bool) async -> [String: Any] {
        guard let gitHub else {
            // No GitHub for this pane (a preview, a page with no Cloud): the picker shows no section.
            if case .status = self { return AgentPaneReply.success(["state": "unavailable", "repos_scope": NSNull()]) }
            return AgentPaneReply.failure(code: "github.unavailable", message: AgentPaneModel.gitHubUnavailableMessage)
        }
        switch self {
        case .status:
            let status = await gitHub.status()
            return AgentPaneReply.success(["state": status.state, "repos_scope": status.reposScope.map { $0 as Any } ?? NSNull()])
        case .connect:
            guard gesture() else { return AgentPaneModel.transportFailure(.gestureRequired) }
            switch await gitHub.connect() {
            case .opened: return AgentPaneReply.success(["opened": true])
            // Nothing to open: the team is connected already (the picker reads `github.status` again).
            case .alreadyConnected: return AgentPaneReply.success(["opened": false])
            case .failed(let message):
                return AgentPaneReply.failure(code: "github.connect_failed", message: message.isEmpty ? AgentPaneModel.gitHubUnavailableMessage : message)
            }
        case .repos(let query):
            switch await gitHub.repos(query) {
            case .success(let listed):
                let repos: [[String: Any]] = listed.repos.map { repo in
                    ["full_name": repo.fullName, "private": repo.isPrivate, "default_branch": repo.defaultBranch.map { $0 as Any } ?? NSNull()]
                }
                return AgentPaneReply.success(["repos": repos, "truncated": listed.truncated])
            case .failure(.notConnected):
                return AgentPaneReply.failure(code: "github.not_connected", message: AgentPaneModel.gitHubNotConnectedMessage)
            case .failure(.unavailable):
                return AgentPaneReply.failure(code: "github.unavailable", message: AgentPaneModel.gitHubUnavailableMessage)
            }
        }
    }
}

/// What answers the picker's GitHub methods for every pane: the signed-in person's session and team
/// (``CloudGitHubPicker``) and Settings > Accounts' Connect GitHub. The App sets it.
public struct AgentPaneGitHub {
    /// `state` (`ready`, `not_connected`, `unavailable`) and `repos_scope` (`all`, `selected`, nil).
    public var status: @MainActor () async -> (state: String, reposScope: String?)
    public var connect: @MainActor () async -> AgentPaneGitHubConnect
    public var repos: @MainActor (String?) async -> Result<CloudGitHubRepos, CloudGitHubRepos.Failure>

    public init(status: @escaping @MainActor () async -> (state: String, reposScope: String?),
                connect: @escaping @MainActor () async -> AgentPaneGitHubConnect,
                repos: @escaping @MainActor (String?) async -> Result<CloudGitHubRepos, CloudGitHubRepos.Failure>) {
        (self.status, self.connect, self.repos) = (status, connect, repos)
    }

    /// The App's: `picker` reads as the person, `connect` is the shared Connect GitHub.
    @MainActor public static func live(_ picker: CloudGitHubPicker, connect: @escaping @MainActor () async -> AgentPaneGitHubConnect) -> AgentPaneGitHub {
        AgentPaneGitHub(status: { await picker.status() }, connect: connect, repos: { await picker.repos(query: $0) })
    }
}

/// How Connect GitHub ended.
public enum AgentPaneGitHubConnect: Equatable, Sendable {
    /// The App's installation page opened in the person's browser.
    case opened
    case alreadyConnected
    /// The words the person reads (signed out, no App here, or the connect failed).
    case failed(String)

    /// The shared Connect GitHub's result (`accounts.githubConnect`, GitHubConnections' `connectResult()`):
    /// `pending` once the installation page opened, `connected` when there was nothing to open, else its detail.
    public init(_ result: Result<[String: ActionResultValue], ActionWorkFailure>) {
        switch result {
        case .success(let fields) where fields["status"] == .string("pending"): self = .opened
        case .success(let fields) where fields["status"] == .string("connected"): self = .alreadyConnected
        case .success(let fields):
            if case .string(let detail)? = fields["detail"] { self = .failed(detail) } else { self = .failed("") }
        case .failure(let failure): self = .failed(failure.message)
        }
    }
}

/// A chat folder that names a GitHub repository instead of a folder on this Mac: `github:owner/name`.
/// Only a Cloud start takes one (its machine clones the repository); a chat here is refused.
public nonisolated enum AgentPaneGitHubFolder {
    public static let prefix = "github:"

    public static func isGitHub(_ folder: String) -> Bool { folder.hasPrefix(prefix) }

    /// `owner/name` of `github:owner/name`; nil for any other text, a bad name included.
    public static func repository(_ folder: String) -> String? {
        guard isGitHub(folder) else { return nil }
        let name = String(folder.dropFirst(prefix.count))
        return CloudGitHubRepos.isFullName(name) ? name : nil
    }
}
