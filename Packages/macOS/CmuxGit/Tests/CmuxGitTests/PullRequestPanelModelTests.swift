import Testing
@testable import CmuxGit

@Suite struct PullRequestPanelModelTests {
    @Test @MainActor func refreshFailurePreservesCachedContent() async {
        let input = PullRequestWorkspaceInput(directory: "/repo", branchHint: "feature")
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "feature",
            repositorySlug: "example/repo"
        )
        let cached = PullRequestPanelContent.noPullRequest(context)
        let service = StubPullRequestPanelService(
            cached: cached,
            refreshResult: .failure(.refreshFailed)
        )
        let model = PullRequestPanelModel(service: service)

        model.setVisible(true)
        await model.activate(input)

        #expect(model.phase == .failed(cached: cached, error: .refreshFailed))
        #expect(model.phase.displayedContent == cached)
        model.setVisible(false)
    }

    @Test @MainActor func cachedContentCannotTriggerMergeAfterRefreshFailure() async throws {
        let input = PullRequestWorkspaceInput(directory: "/repo", branchHint: "feature")
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "feature",
            repositorySlug: "example/repo"
        )
        let cached = PullRequestPanelContent.pullRequest(PullRequestPanelSnapshot(
            context: context,
            pullRequest: try PullRequestFixtureLoader().pullRequest(),
            checks: [],
            checksStatus: .success,
            unresolvedReviewThreadCount: nil,
            mergeMethods: [.squash]
        ))
        let service = StubPullRequestPanelService(
            cached: cached,
            refreshResult: .failure(.refreshFailed)
        )
        let model = PullRequestPanelModel(service: service)

        model.setVisible(true)
        await model.activate(input)
        await model.merge(whenReady: false, for: input)

        #expect(await service.mergeCallCount == 0)
        model.setVisible(false)
    }

    @Test @MainActor func autoMergeCannotBypassConfirmationWhenDirectMergeIsAvailable() async throws {
        let input = PullRequestWorkspaceInput(directory: "/repo", branchHint: "feature")
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "feature",
            repositorySlug: "example/repo"
        )
        let content = PullRequestPanelContent.pullRequest(PullRequestPanelSnapshot(
            context: context,
            pullRequest: try PullRequestFixtureLoader().pullRequest(),
            checks: [],
            checksStatus: .success,
            unresolvedReviewThreadCount: nil,
            mergeMethods: [.squash]
        ))
        let service = StubPullRequestPanelService(cached: nil, refreshResult: .success(content))
        let model = PullRequestPanelModel(service: service)

        model.setVisible(true)
        await model.activate(input)
        await model.merge(whenReady: true, for: input)

        #expect(await service.mergeCallCount == 0)
        model.setVisible(false)
    }

    @Test @MainActor func staleMergeConfirmationCannotMergeARefreshedHead() async throws {
        let input = PullRequestWorkspaceInput(directory: "/repo", branchHint: "feature")
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "feature",
            repositorySlug: "example/repo"
        )
        let pullRequest = try PullRequestFixtureLoader().pullRequest()
        let content = PullRequestPanelContent.pullRequest(PullRequestPanelSnapshot(
            context: context,
            pullRequest: pullRequest,
            checks: [],
            checksStatus: .success,
            unresolvedReviewThreadCount: nil,
            mergeMethods: [.squash]
        ))
        let service = StubPullRequestPanelService(cached: nil, refreshResult: .success(content))
        let model = PullRequestPanelModel(service: service)
        let staleConfirmation = PullRequestMergeConfirmation(
            context: context,
            number: pullRequest.number,
            headRefOid: "previous-head-commit",
            method: .squash
        )
        model.setVisible(true)
        await model.activate(input)

        await model.merge(confirmation: staleConfirmation, for: input)

        #expect(await service.mergeCallCount == 0)
        model.setVisible(false)
    }

    @Test @MainActor func branchTransitionRejectsActionsFromOldContent() async throws {
        let oldInput = PullRequestWorkspaceInput(directory: "/repo", branchHint: "old")
        let visibleInput = PullRequestWorkspaceInput(directory: "/repo", branchHint: "new")
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "old",
            repositorySlug: "example/repo"
        )
        let pullRequestContent = PullRequestPanelContent.pullRequest(PullRequestPanelSnapshot(
            context: context,
            pullRequest: try PullRequestFixtureLoader().pullRequest(),
            checks: [],
            checksStatus: .success,
            unresolvedReviewThreadCount: nil,
            mergeMethods: [.squash]
        ))
        let pullRequestService = StubPullRequestPanelService(
            cached: nil,
            refreshResult: .success(pullRequestContent)
        )
        let pullRequestModel = PullRequestPanelModel(service: pullRequestService)
        pullRequestModel.setVisible(true)
        await pullRequestModel.activate(oldInput)
        pullRequestModel.visibleInputDidChange(to: visibleInput)

        await pullRequestModel.merge(whenReady: false, for: oldInput)
        await pullRequestModel.disableAutoMerge(for: oldInput)

        #expect(await pullRequestService.mergeCallCount == 0)
        #expect(await pullRequestService.disableAutoMergeCallCount == 0)
        pullRequestModel.setVisible(false)

        let noPullRequestContent = PullRequestPanelContent.noPullRequest(context)
        let noPullRequestService = StubPullRequestPanelService(
            cached: nil,
            refreshResult: .success(noPullRequestContent)
        )
        let noPullRequestModel = PullRequestPanelModel(service: noPullRequestService)
        noPullRequestModel.setVisible(true)
        await noPullRequestModel.activate(oldInput)
        noPullRequestModel.visibleInputDidChange(to: visibleInput)

        await noPullRequestModel.createPullRequest(for: oldInput)

        #expect(await noPullRequestService.createPullRequestCallCount == 0)
        noPullRequestModel.setVisible(false)
    }

    @Test @MainActor func manualRefreshCoalescesWithActiveRefresh() async {
        let input = PullRequestWorkspaceInput(directory: "/repo", branchHint: "feature")
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "feature",
            repositorySlug: "example/repo"
        )
        let content = PullRequestPanelContent.noPullRequest(context)
        let service = StubPullRequestPanelService(
            cached: content,
            refreshResult: .success(content),
            suspendsRefresh: true
        )
        let model = PullRequestPanelModel(service: service)
        model.setVisible(true)

        let activation = Task { await model.activate(input) }
        await service.waitForRefreshStart()
        await model.refresh()

        #expect(await service.refreshCallCount == 1)
        await service.resumeRefreshes()
        await activation.value
        model.setVisible(false)
    }

    @Test @MainActor func hidingDuringRefreshAllowsRefreshAfterReopening() async {
        let input = PullRequestWorkspaceInput(directory: "/repo", branchHint: "feature")
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "feature",
            repositorySlug: "example/repo"
        )
        let content = PullRequestPanelContent.noPullRequest(context)
        let service = StubPullRequestPanelService(
            cached: nil,
            refreshResult: .success(content),
            suspendsRefresh: true
        )
        let model = PullRequestPanelModel(service: service)
        model.setVisible(true)

        let firstActivation = Task { await model.activate(input) }
        await service.waitForRefreshCallCount(1)
        model.setVisible(false)

        #expect(model.phase == .idle)
        #expect(!model.phase.isRefreshInFlight)

        model.setVisible(true)
        let secondActivation = Task { await model.activate(input) }
        await service.waitForRefreshCallCount(2)

        #expect(await service.refreshCallCount == 2)
        await service.resumeRefreshes()
        await firstActivation.value
        await secondActivation.value
        model.setVisible(false)
    }

    @Test @MainActor func oldMutationCannotFinishAReplacementMutationAfterReturningToInput() async {
        let inputA = PullRequestWorkspaceInput(directory: "/repo", branchHint: "a")
        let inputB = PullRequestWorkspaceInput(directory: "/repo", branchHint: "b")
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "a",
            repositorySlug: "example/repo"
        )
        let content = PullRequestPanelContent.noPullRequest(context)
        let service = StubPullRequestPanelService(
            cached: nil,
            refreshResult: .success(content),
            suspendsCreatePullRequest: true
        )
        let model = PullRequestPanelModel(service: service)
        model.setVisible(true)
        await model.activate(inputA)

        let oldMutation = Task { await model.createPullRequest(for: inputA) }
        await service.waitForCreatePullRequestCallCount(1)
        model.visibleInputDidChange(to: inputB)
        await model.activate(inputB)
        model.visibleInputDidChange(to: inputA)
        await model.activate(inputA)

        let replacementMutation = Task { await model.createPullRequest(for: inputA) }
        await service.waitForCreatePullRequestCallCount(2)
        await service.resumeNextCreatePullRequest()
        await oldMutation.value

        #expect(model.actionPhase == .creatingPullRequest)

        await service.resumeNextCreatePullRequest()
        await replacementMutation.value
        #expect(model.actionPhase == .idle)
        model.setVisible(false)
    }

    @Test @MainActor func hidingDuringMutationAllowsAReplacementAfterReopening() async {
        let input = PullRequestWorkspaceInput(directory: "/repo", branchHint: "feature")
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "feature",
            repositorySlug: "example/repo"
        )
        let content = PullRequestPanelContent.noPullRequest(context)
        let service = StubPullRequestPanelService(
            cached: nil,
            refreshResult: .success(content),
            suspendsCreatePullRequest: true
        )
        let model = PullRequestPanelModel(service: service)
        model.setVisible(true)
        await model.activate(input)

        let hiddenMutation = Task { await model.createPullRequest(for: input) }
        await service.waitForCreatePullRequestCallCount(1)
        model.setVisible(false)

        #expect(model.actionPhase == .idle)

        model.setVisible(true)
        await model.activate(input)
        let replacementMutation = Task { await model.createPullRequest(for: input) }
        await service.waitForCreatePullRequestCallCount(2)
        await service.resumeNextCreatePullRequest()
        await hiddenMutation.value

        #expect(model.actionPhase == .creatingPullRequest)

        await service.resumeNextCreatePullRequest()
        await replacementMutation.value
        #expect(model.actionPhase == .idle)
        model.setVisible(false)
    }
}
