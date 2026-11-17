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
                                           report: @MainActor (Step) -> Void) async throws -> String? {
        guard let repository, let slash = repository.firstIndex(of: "/") else { return nil }
        let name = String(repository[repository.index(after: slash)...])
        let row = { (state: String) in Step(name: "folder", folder: name, machine: machineName, size: size, cloneState: state) }
        report(row("running"))
        let bootstrap = CloudMachineBootstrap(kind: .plain, contents: CloudMachineBootstrap.noScript,
                                              repo: CloudMachineRepo(owner: String(repository[..<slash]), name: name))
        let ended: CloudMachineBootstrap.Run
        if await bootstrap.start(name: nil, on: machine).status == "failed" {
            ended = .repoFailed(repo: repository)
        } else {
            ended = await bootstrap.waitForRun(on: machine, bound: Self.cloneBound)
        }
        guard case .finished(let path?) = ended else {
            report(row("failed"))
            if case .needsGitHub = ended { throw AgentPaneCloudRepositoryRefusal.needsGitHub(repository) }
            throw AgentPaneCloudRepositoryRefusal.failed(repository)
        }
        report(row("done"))
        return path
    }

    /// How long a start waits for its clone: a large repository's clone, never the bootstrap's three hours.
    static let cloneBound: Duration = .seconds(20 * 60)
}

/// Why a Cloud start in a GitHub repository started no chat: the card's words, with Retry.
public nonisolated enum AgentPaneCloudRepositoryRefusal: CloudStartRetriesOnMachine, Equatable, Sendable {
    /// The machine has no GitHub access to the repository: the card offers Connect GitHub, then Retry
    /// (`seed.needs_github`, the code a seed's clone refuses with).
    case needsGitHub(String)
    /// The clone did not finish (a missing repository, the machine did not answer).
    case failed(String)

    public static let needsGitHubCode = "seed.needs_github"

    public var reply: [String: Any] {
        switch self {
        case .needsGitHub(let repository):
            AgentPaneReply.failure(code: Self.needsGitHubCode, message: Self.needsAccessMessage(repository),
                                   details: ["repo": repository], retryable: true, origin: "native")
        case .failed(let repository):
            AgentPaneReply.failure(code: "cloud_start_failed", message: Self.failedMessage(repository),
                                   details: ["repo": repository], retryable: true, origin: "native")
        }
    }
}
