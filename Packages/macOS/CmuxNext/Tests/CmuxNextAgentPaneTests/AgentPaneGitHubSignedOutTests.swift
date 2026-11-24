import Testing
@testable import CmuxNextAgentPane

/// GitHub integration audit fix 10: a signed-out gh says to sign in, not gh's own setup text.
struct AgentPaneGitHubSignedOutTests {
    @Test func signedOutGhNamesTheSignInStep() {
        let outcome = AgentPaneGitProcess.Outcome(status: 4, text: "To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.")
        #expect(AgentPaneGitPullRequest.message(outcome) == AgentPaneGitPullRequest.gitHubSignedOutMessage)
    }

    @Test func otherFailuresKeepGhsReason() {
        let outcome = AgentPaneGitProcess.Outcome(status: 1, text: "Warning: 2 uncommitted changes\npull request create failed: GraphQL: No commits between main and topic")
        #expect(AgentPaneGitPullRequest.message(outcome) == "pull request create failed: GraphQL: No commits between main and topic")
    }
}
