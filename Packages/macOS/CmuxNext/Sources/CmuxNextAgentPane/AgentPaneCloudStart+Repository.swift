public import CmuxNextCloud
import Foundation

/// A Cloud start in a GitHub repository with no folder on this Mac (the page's `cwd` is
/// `github:owner/name`, ``AgentPaneGitHubFolder``): nothing is copied from this Mac. The machine clones
/// the repository with the GitHub access it has (the cmux GitHub App's git helper) through New Cloud
/// Workspace's From repository step (``CloudMachineBootstrap`` with only its repo step, into `~/work/NAME`),
/// and the chat starts in the clone.
extension AgentPaneCloudStart {
    /// The clone's folder on the machine, or nil for a start that names no repository. `report` gets the
    /// card's clone row as it runs and ends. A machine with no access to the repository throws
    /// ``AgentPaneCloudRepositoryRefusal/needsGitHub(_:)``: the card's Connect GitHub, then Retry.
    @MainActor public func cloneRepository(on machine: CloudMachineBootstrap.Machine, machineName: String, size: String?,
                                           gitHubLogin: AgentPaneGitHubLogin = .none,
                                           report: @MainActor (Step) -> Void) async throws -> String? {
        guard let repository, let slash = repository.firstIndex(of: "/") else { return nil }
        let name = String(repository[repository.index(after: slash)...])
        let row = { (state: String) in Step(name: "folder", folder: name, machine: machineName, size: size, cloneState: state) }
        report(row("running"))
        let bootstrap = CloudMachineBootstrap(kind: .plain, contents: CloudMachineBootstrap.noScript,
                                              repo: CloudMachineRepo(owner: String(repository[..<slash]), name: name))
        // `running` is another start's run (a reused machine): this start's files were dropped, and that run's
        // answer names its own repository or none. Wait it out, then start this clone once more; a machine
        // still busy after that fails here, with Retry.
        var started = await bootstrap.start(name: nil, on: machine).status
        if started == "running" {
            _ = await bootstrap.waitForRun(on: machine, bound: Self.cloneBound)
            started = await bootstrap.start(name: nil, on: machine).status
        }
        let ended: CloudMachineBootstrap.Run = Self.clonesHere(started)
            ? await bootstrap.waitForRun(on: machine, bound: Self.cloneBound) : .repoFailed(repo: repository)
        guard case .finished(let path?) = ended else {
            report(row("failed"))
            if case .needsGitHub = ended { throw AgentPaneCloudRepositoryRefusal.needsGitHub(repository, login: gitHubLogin) }
            throw AgentPaneCloudRepositoryRefusal.failed(repository)
        }
        report(row("done"))
        return path
    }

    /// Whether a bootstrap start's status means the run to wait for is this start's own clone: `started`, or
    /// `skipped` (this same repository step already finished here). Never `running` (another start's run) or `failed`.
    nonisolated static func clonesHere(_ status: String) -> Bool { status == "started" || status == "skipped" }

    /// How long a start waits for its clone: a large repository's clone, never the bootstrap's three hours.
    static let cloneBound: Duration = .seconds(20 * 60)
}

/// Why a Cloud start in a GitHub repository started no chat: the card's words, with Retry.
public nonisolated enum AgentPaneCloudRepositoryRefusal: CloudStartRetriesOnMachine, Equatable, Sendable {
    /// The machine has no GitHub access to the repository: the card offers Connect GitHub, then Retry
    /// (`seed.needs_github`, the code a seed's clone refuses with).
    case needsGitHub(String, login: AgentPaneGitHubLogin = .none)
    /// The clone did not finish (a missing repository, the machine did not answer).
    case failed(String)

    public static let needsGitHubCode = "seed.needs_github"

    public var reply: [String: Any] {
        switch self {
        case .needsGitHub(let repository, let login):
            AgentPaneReply.failure(code: Self.needsGitHubCode, message: Self.needsAccessMessage(repository, login: login),
                                   details: ["repo": repository].merging(login.details) { $1 }, retryable: true, origin: "native")
        case .failed(let repository):
            AgentPaneReply.failure(code: "cloud_start_failed", message: Self.failedMessage(repository),
                                   details: ["repo": repository], retryable: true, origin: "native")
        }
    }
}

/// The person's own GitHub login on the start's machine, for the card when the machine can't reach the repository
/// (`CloudGitHubLoginCarry`): carried (and which login, so the card says that account can't reach it), none on this
/// Mac (the card's Sign in with GitHub), or not carried (off, or the machine refused it: the card's Use my GitHub login).
public nonisolated enum AgentPaneGitHubLogin: Equatable, Sendable {
    case carried(login: String?)
    case none
    case notCarried

    /// What the start's carry did: nil (the setting is off) and a failed carry are not carried; no gh login is none.
    public init(carry: CloudDaemon.GitHubLoginCarry?) {
        switch carry {
        case .carried(let login): self = .carried(login: login)
        case .noLogin: self = .none
        case .failed, .forgotten, nil: self = .notCarried
        }
    }

    /// The reply's `details` fields (`githubLogin`: `carried`, `none` or `not_carried`; `githubUser` when known).
    public var details: [String: String] {
        switch self {
        case .carried(let login?): ["githubLogin": "carried", "githubUser": login]
        case .carried(nil): ["githubLogin": "carried"]
        case .none: ["githubLogin": "none"]
        case .notCarried: ["githubLogin": "not_carried"]
        }
    }
}
