import Foundation

/// The injected async boundary between pull-request panel state and GitHub CLI operations.
public protocol PullRequestPanelServing: Sendable {
    /// Returns the last successful content cached for the input's canonical repository and branch.
    /// - Parameter input: The workspace checkout to resolve.
    /// - Returns: Cached content, or `nil` when the branch has not loaded successfully.
    func cachedContent(for input: PullRequestWorkspaceInput) async -> PullRequestPanelContent?

    /// Refreshes the branch's pull-request content via the GitHub CLI.
    /// - Parameter input: The workspace checkout to resolve.
    /// - Returns: Fresh pull-request or no-pull-request content.
    /// - Throws: A ``PullRequestPanelServiceError`` when repository discovery or GitHub fails.
    func refresh(for input: PullRequestWorkspaceInput) async throws -> PullRequestPanelContent

    /// Merges a pull request immediately or enables auto-merge.
    /// - Parameters:
    ///   - number: The pull-request number.
    ///   - context: The repository and branch identity.
    ///   - headRefOid: The displayed head commit that the merge must still match.
    ///   - method: The requested merge method.
    ///   - whenReady: `true` to enable auto-merge; `false` to merge immediately.
    /// - Throws: ``PullRequestPanelServiceError/mergeFailed`` when `gh pr merge` fails.
    func merge(
        number: Int,
        context: PullRequestPanelContext,
        headRefOid: String,
        method: PullRequestMergeMethod,
        whenReady: Bool
    ) async throws

    /// Disables auto-merge for a pull request.
    /// - Parameters:
    ///   - number: The pull-request number.
    ///   - context: The repository and branch identity.
    ///   - headRefOid: The displayed head commit that must still match.
    /// - Throws: ``PullRequestPanelServiceError/mergeFailed`` when the command fails.
    func disableAutoMerge(
        number: Int,
        context: PullRequestPanelContext,
        headRefOid: String
    ) async throws

    /// Opens GitHub's web-based pull-request creation flow for the branch.
    /// - Parameter context: The repository and branch identity.
    /// - Throws: ``PullRequestPanelServiceError/createFailed`` when the command fails.
    func createPullRequest(context: PullRequestPanelContext) async throws
}
