@testable import CmuxGit

actor StubPullRequestPanelService: PullRequestPanelServing {
    let cached: PullRequestPanelContent?
    let refreshResult: Result<PullRequestPanelContent, PullRequestPanelServiceError>
    private(set) var mergeCallCount = 0
    private(set) var disableAutoMergeCallCount = 0
    private(set) var createPullRequestCallCount = 0
    private(set) var refreshCallCount = 0
    private var refreshStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshContinuations: [CheckedContinuation<Void, Never>] = []
    private let suspendsRefresh: Bool

    init(
        cached: PullRequestPanelContent?,
        refreshResult: Result<PullRequestPanelContent, PullRequestPanelServiceError>,
        suspendsRefresh: Bool = false
    ) {
        self.cached = cached
        self.refreshResult = refreshResult
        self.suspendsRefresh = suspendsRefresh
    }

    func cachedContent(for input: PullRequestWorkspaceInput) async -> PullRequestPanelContent? {
        _ = input
        return cached
    }

    func refresh(for input: PullRequestWorkspaceInput) async throws -> PullRequestPanelContent {
        _ = input
        refreshCallCount += 1
        let waiters = refreshStartWaiters
        refreshStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if suspendsRefresh {
            await withCheckedContinuation { refreshContinuations.append($0) }
        }
        return try refreshResult.get()
    }

    func merge(
        number: Int,
        context: PullRequestPanelContext,
        headRefOid: String,
        method: PullRequestMergeMethod,
        whenReady: Bool
    ) async throws {
        _ = (number, context, headRefOid, method, whenReady)
        mergeCallCount += 1
    }

    func disableAutoMerge(
        number: Int,
        context: PullRequestPanelContext,
        headRefOid: String
    ) async throws {
        _ = (number, context, headRefOid)
        disableAutoMergeCallCount += 1
    }

    func createPullRequest(context: PullRequestPanelContext) async throws {
        _ = context
        createPullRequestCallCount += 1
    }

    func waitForRefreshStart() async {
        guard refreshCallCount == 0 else { return }
        await withCheckedContinuation { refreshStartWaiters.append($0) }
    }

    func resumeRefreshes() {
        let continuations = refreshContinuations
        refreshContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}
