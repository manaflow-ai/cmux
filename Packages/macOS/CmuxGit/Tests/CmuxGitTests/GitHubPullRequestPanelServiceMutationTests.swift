import Testing
@testable import CmuxGit

@Suite struct GitHubPullRequestPanelServiceMutationTests {
    @Test func mergePinsRepositoryAndDisplayedHeadCommit() async throws {
        let runner = RecordingPullRequestCommandRunner()
        let service = GitHubPullRequestPanelService(commandRunner: runner)
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "feature",
            repositorySlug: "example/repo"
        )

        try await service.merge(
            number: 42,
            context: context,
            headRefOid: "abc123",
            method: .squash,
            whenReady: false
        )

        let arguments = await runner.lastArguments
        #expect(arguments == [
            "pr", "merge", "42", "--squash",
            "--repo", "example/repo", "--match-head-commit", "abc123",
        ])
    }

    @Test func cacheEvictsLeastRecentlyUsedContext() async {
        let service = GitHubPullRequestPanelService()
        for index in 0 ... GitHubPullRequestPanelService.cacheCapacity {
            let context = PullRequestPanelContext(
                repositoryRoot: "/repo/\(index)",
                branch: "feature-\(index)",
                repositorySlug: "example/repo-\(index)"
            )
            await service.storeCachedContent(.noPullRequest(context), for: context)
        }

        let cache = await service.cacheByContext
        #expect(cache.count == GitHubPullRequestPanelService.cacheCapacity)
        #expect(cache.keys.contains { $0.repositoryRoot == "/repo/0" } == false)
    }

    @Test func disableAutoMergePinsRepositoryAndDisplayedHeadCommit() async throws {
        let runner = RecordingPullRequestCommandRunner()
        let service = GitHubPullRequestPanelService(commandRunner: runner)
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "feature",
            repositorySlug: "example/repo"
        )

        try await service.disableAutoMerge(
            number: 42,
            context: context,
            headRefOid: "abc123"
        )

        #expect(await runner.lastArguments == [
            "pr", "merge", "42", "--disable-auto",
            "--repo", "example/repo", "--match-head-commit", "abc123",
        ])
    }

    @Test func createPullRequestFailsClosedWhenDisplayedContextCannotBeRevalidated() async {
        let runner = RecordingPullRequestCommandRunner()
        let service = GitHubPullRequestPanelService(commandRunner: runner)
        let context = PullRequestPanelContext(
            repositoryRoot: "/path/that/does/not/exist",
            branch: "feature",
            repositorySlug: "example/repo"
        )

        do {
            try await service.createPullRequest(context: context)
            Issue.record("Expected pull-request creation to fail closed")
        } catch let error as PullRequestPanelServiceError {
            #expect(error == .createFailed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await runner.lastArguments.isEmpty)
    }

    @Test func commentsFailureIsOptionalAndRepositoryBound() async {
        let runner = RecordingPullRequestCommandRunner()
        let service = GitHubPullRequestPanelService(commandRunner: runner)
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "feature",
            repositorySlug: "example/repo"
        )

        let comments = await service.fetchComments(number: 42, context: context)

        #expect(comments == nil)
        #expect(await runner.lastArguments == [
            "pr", "view", "42", "--repo", "example/repo", "--json", "comments",
            "--jq", "{comments: [.comments[] | select(.threadId != null and .isResolved != null) | {threadId, isResolved}]}",
        ])
    }

    @Test func olderRefreshCannotOverwriteNewerCompletedRefresh() async throws {
        let service = GitHubPullRequestPanelService()
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "feature",
            repositorySlug: "example/repo"
        )
        let oldSequence = await service.beginRefresh(for: context)
        let newSequence = await service.beginRefresh(for: context)
        let newContent = PullRequestPanelContent.pullRequest(PullRequestPanelSnapshot(
            context: context,
            pullRequest: try PullRequestFixtureLoader().pullRequest(),
            checks: [],
            checksStatus: .success,
            unresolvedReviewThreadCount: nil,
            mergeMethods: [.squash]
        ))

        await service.storeCachedContentIfLatest(
            newContent,
            for: context,
            refreshSequence: newSequence
        )
        await service.finishRefresh(newSequence, for: context)
        await service.storeCachedContentIfLatest(
            .noPullRequest(context),
            for: context,
            refreshSequence: oldSequence
        )

        let cache = await service.cacheByContext
        #expect(cache[context] == newContent)
    }
}
