import AppKit

/// What the palette's git actions ask of the page's changes view.
public nonisolated enum AgentPaneGitAction: String, Sendable {
    /// Opens the changes view with the commit form, its message field focused.
    case commit = "gitCommit"
    /// Opens the changes view and pushes the branch, as its Push button does.
    case push = "gitPush"
}

extension AgentPaneView {
    /// `agentPane.git.commit` and `agentPane.git.push` enter the same page
    /// path as the changes view's Commit and Push buttons; the page refuses
    /// with its own message when the chat has no local repository.
    public func runGitAction(_ action: AgentPaneGitAction) {
        evaluateScript("window.cmuxAcpmuxBridge?.command?.(\"\(action.rawValue)\");")
    }
}
