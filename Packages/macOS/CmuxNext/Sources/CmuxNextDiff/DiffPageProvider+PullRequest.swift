public import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// An optional local git capability: push through Rust and open the branch's pull request.
public protocol DiffGitPullRequestRunning: DiffGitRunning {
    func pullRequest(in repository: String) async -> AgentPaneGitPullRequest.Outcome
}

extension DiffAgentGit: DiffGitPullRequestRunning {
    public func pullRequest(in repository: String) async -> AgentPaneGitPullRequest.Outcome {
        let link = link
        let key = UUID().uuidString
        return await AgentPaneGitPullRequest.open(in: repository) { @MainActor _, expectedHead in
            // Rust sets an upstream only when this branch has none and refuses an
            // ambiguous upstream branch name before pushing.
            _ = try await link.write(.push(sessionId: DiffPageProvider.gitSession, expectedHead: expectedHead, setUpstream: false, key: key),
                                     in: repository)
        }
    }
}

extension DiffPageProvider {
    static let pullRequestOp = "cmux.diff.git.pullRequest"

    /// The page supplies no path: both the push and the PR use this tab's repository grant.
    func pullRequestCall(context: PageCallContext) async throws -> JSONValue {
        guard let git = git as? any DiffGitPullRequestRunning, !git.isRemote,
              let onPullRequestOpened else { throw PageError.unknownOp(Self.pullRequestOp) }
        guard context.userGesture else {
            throw PageError(code: "transport.gesture_required", message: AgentPaneGitStage.needsGestureMessage)
        }
        let repository = try await gitRepository()
        guard !isClosed else { throw PageError.closed }
        let outcome = await git.pullRequest(in: repository)
        guard !isClosed else { throw PageError.closed }
        guard try await gitRepository() == repository else { throw PageError.closed }
        switch outcome {
        case .opened(let text, let number):
            guard let url = URL(string: text), url.scheme == "https" else {
                throw PageError(code: "git.failed", message: DiffPageStrings.pullRequestFailed)
            }
            onPullRequestOpened(url)
            return ["url": .string(text), "number": number.map { .number(Double($0)) } ?? .null]
        case .formOpened(let text):
            // `gh pr create --web` already opened this compare form. Do not route it through
            // LinkRouter a second time; the result lets the page finish its write transition.
            guard let url = URL(string: text), url.scheme == "https" else {
                throw PageError(code: "git.failed", message: DiffPageStrings.pullRequestFailed)
            }
            return ["url": .string(text), "number": .null]
        case .refused(let message):
            throw PageError(code: "git.failed", message: message)
        default:
            throw PageError(code: "git.failed", message: DiffPageStrings.pullRequestFailed)
        }
    }
}
