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
            pullRequest: try pullRequestFixture(),
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
        await model.merge(whenReady: false)

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
            pullRequest: try pullRequestFixture(),
            checks: [],
            checksStatus: .success,
            unresolvedReviewThreadCount: nil,
            mergeMethods: [.squash]
        ))
        let service = StubPullRequestPanelService(cached: nil, refreshResult: .success(content))
        let model = PullRequestPanelModel(service: service)

        model.setVisible(true)
        await model.activate(input)
        await model.merge(whenReady: true)

        #expect(await service.mergeCallCount == 0)
        model.setVisible(false)
    }
}
