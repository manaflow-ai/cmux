@testable import CmuxGit

actor StubPullRequestPanelService: PullRequestPanelServing {
    let cached: PullRequestPanelContent?
    let refreshResult: Result<PullRequestPanelContent, PullRequestPanelServiceError>
    private(set) var mergeCallCount = 0
    private(set) var disableAutoMergeCallCount = 0
    private(set) var createPullRequestCallCount = 0
    private(set) var refreshCallCount = 0
    private var createPullRequestCallCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var createPullRequestContinuations: [CheckedContinuation<Void, Never>] = []
    private var refreshCallCountWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var refreshContinuations: [CheckedContinuation<Void, Never>] = []
    private let suspendsCreatePullRequest: Bool
    private let suspendsRefresh: Bool

    init(
        cached: PullRequestPanelContent?,
        refreshResult: Result<PullRequestPanelContent, PullRequestPanelServiceError>,
        suspendsCreatePullRequest: Bool = false,
        suspendsRefresh: Bool = false
    ) {
        self.cached = cached
        self.refreshResult = refreshResult
        self.suspendsCreatePullRequest = suspendsCreatePullRequest
        self.suspendsRefresh = suspendsRefresh
    }

    func cachedContent(for input: PullRequestWorkspaceInput) async -> PullRequestPanelContent? {
        _ = input
        return cached
    }

    func refresh(for input: PullRequestWorkspaceInput) async throws -> PullRequestPanelContent {
        _ = input
        refreshCallCount += 1
        let waiters = refreshCallCountWaiters.removeValue(forKey: refreshCallCount) ?? []
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
        let waiters = createPullRequestCallCountWaiters
            .removeValue(forKey: createPullRequestCallCount) ?? []
        waiters.forEach { $0.resume() }
        if suspendsCreatePullRequest {
            await withCheckedContinuation { createPullRequestContinuations.append($0) }
        }
    }

    func waitForCreatePullRequestCallCount(_ count: Int) async {
        guard createPullRequestCallCount < count else { return }
        await withCheckedContinuation { continuation in
            createPullRequestCallCountWaiters[count, default: []].append(continuation)
        }
    }

    func resumeNextCreatePullRequest() {
        guard !createPullRequestContinuations.isEmpty else { return }
        createPullRequestContinuations.removeFirst().resume()
    }

    func waitForRefreshStart() async {
        await waitForRefreshCallCount(1)
    }

    func waitForRefreshCallCount(_ count: Int) async {
        guard refreshCallCount < count else { return }
        await withCheckedContinuation { continuation in
            refreshCallCountWaiters[count, default: []].append(continuation)
        }
    }

    func resumeRefreshes() {
        let continuations = refreshContinuations
        refreshContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}
