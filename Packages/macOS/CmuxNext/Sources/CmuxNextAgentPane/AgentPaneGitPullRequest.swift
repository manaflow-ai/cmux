import Foundation

/// The Changes view's Create PR (cx-tcwj, Codex desktop's): `git.pullRequest` with `{cwd}`.
public nonisolated struct AgentPaneGitPullRequest: Equatable, Sendable {
    /// The chat's folder, absolute.
    public let cwd: String

    public init?(params: [String: Any]?) {
        guard let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0") else { return nil }
        self.cwd = cwd
    }

    /// The pull request the run opened, or why it did not.
    enum Outcome: Equatable {
        case opened(url: String, number: Int?)
        case refused(String)
    }

    @concurrent static func run(_ request: AgentPaneGitPullRequest, roots: [String], home: String = NSHomeDirectory(),
                                gh: String?) async -> Outcome {
        .refused("")
    }
}

extension AgentPaneGitPullRequest {
    /// No `gh` in the user's usual install folders.
    nonisolated static var noGitHubCLIMessage: String {
        String(localized: "agentPane.error.gitNoGitHubCLI", defaultValue: "Install the GitHub CLI (gh) to open a pull request.",
               bundle: .module)
    }

    /// The repository has no branch checked out.
    nonisolated static var detachedMessage: String {
        String(localized: "agentPane.error.gitDetached", defaultValue: "Check out a branch to open a pull request.", bundle: .module)
    }

    /// The branch has no upstream and the repository no remote to push it to.
    nonisolated static var noRemoteMessage: String {
        String(localized: "agentPane.error.gitNoRemote", defaultValue: "This repository has no remote to push to.", bundle: .module)
    }

    /// `git.pullRequest` arrived without a real click or key press in the pane.
    nonisolated static var needsGestureMessage: String {
        String(localized: "agentPane.error.gitPullRequestGesture",
               defaultValue: "Opening a pull request needs a click or key press in the pane.", bundle: .module)
    }

    /// `git.pullRequest` whose params break its contract.
    nonisolated static var invalidMessage: String {
        String(localized: "agentPane.error.gitPullRequestInvalid", defaultValue: "The app refused to open that pull request.",
               bundle: .module)
    }
}
