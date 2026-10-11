import Foundation

/// The Changes view's git writes (cx-tcwj): Stage and Unstage, Commit, Create PR. Each case is nil
/// when its params break the contract, and nothing runs.
public nonisolated enum AgentPaneGitWrite: Equatable, Sendable {
    case stage(AgentPaneGitStage?)
    case commit(AgentPaneGitCommit?)
    case pullRequest(AgentPaneGitPullRequest?)

    /// The write for `method`, or nil when `method` is none of them.
    init?(method: String, params: [String: Any]?) {
        switch method {
        case "git.stage", "git.unstage": self = .stage(AgentPaneGitStage(method: method, params: params))
        case "git.commit": self = .commit(AgentPaneGitCommit(params: params))
        case "git.pullRequest": self = .pullRequest(AgentPaneGitPullRequest(params: params))
        default: return nil
        }
    }

    /// The reply, from the write's own responder.
    @MainActor func reply(in model: AgentPaneModel) async -> [String: Any] {
        switch self {
        case .stage(let request): await AgentPaneGitStage.reply(to: request, in: model)
        case .commit(let request): await AgentPaneGitCommit.reply(to: request, in: model)
        case .pullRequest(let request): await AgentPaneGitPullRequest.reply(to: request, in: model)
        }
    }
}
