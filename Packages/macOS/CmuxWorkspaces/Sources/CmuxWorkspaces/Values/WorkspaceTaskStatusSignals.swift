/// The live signals a workspace samples to infer its ``WorkspaceTaskStatus``.
/// A pure value so inference is unit-testable without live app state.
public struct WorkspaceTaskStatusSignals: Equatable, Sendable {
    /// Whether any agent in the workspace is waiting on user input.
    public var anyAgentNeedsInput: Bool
    /// Whether any agent in the workspace is running.
    public var anyAgentRunning: Bool
    /// Whether any sidebar pull request is open.
    public var anyOpenPullRequest: Bool
    /// Whether the workspace has any sidebar pull requests at all.
    public var hasPullRequests: Bool
    /// Whether every sidebar pull request is merged or closed.
    public var allPullRequestsMergedOrClosed: Bool
    /// Whether any tracked git working tree is dirty.
    public var isGitDirty: Bool

    /// Creates a signal sample (everything defaults to `false`).
    public init(
        anyAgentNeedsInput: Bool = false,
        anyAgentRunning: Bool = false,
        anyOpenPullRequest: Bool = false,
        hasPullRequests: Bool = false,
        allPullRequestsMergedOrClosed: Bool = false,
        isGitDirty: Bool = false
    ) {
        self.anyAgentNeedsInput = anyAgentNeedsInput
        self.anyAgentRunning = anyAgentRunning
        self.anyOpenPullRequest = anyOpenPullRequest
        self.hasPullRequests = hasPullRequests
        self.allPullRequestsMergedOrClosed = allPullRequestsMergedOrClosed
        self.isGitDirty = isGitDirty
    }
}
