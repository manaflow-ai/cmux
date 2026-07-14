@testable import CmuxGit

actor StubPullRequestPanelService: PullRequestPanelServing {
    let cached: PullRequestPanelContent?
    let refreshResult: Result<PullRequestPanelContent, PullRequestPanelServiceError>

    init(
        cached: PullRequestPanelContent?,
        refreshResult: Result<PullRequestPanelContent, PullRequestPanelServiceError>
    ) {
        self.cached = cached
        self.refreshResult = refreshResult
    }

    func cachedContent(for input: PullRequestWorkspaceInput) async -> PullRequestPanelContent? {
        _ = input
        return cached
    }

    func refresh(for input: PullRequestWorkspaceInput) async throws -> PullRequestPanelContent {
        _ = input
        return try refreshResult.get()
    }

    func merge(
        number: Int,
        context: PullRequestPanelContext,
        method: PullRequestMergeMethod,
        whenReady: Bool
    ) async throws {
        _ = (number, context, method, whenReady)
    }

    func disableAutoMerge(number: Int, context: PullRequestPanelContext) async throws {
        _ = (number, context)
    }

    func createPullRequest(context: PullRequestPanelContext) async throws {
        _ = context
    }
}
