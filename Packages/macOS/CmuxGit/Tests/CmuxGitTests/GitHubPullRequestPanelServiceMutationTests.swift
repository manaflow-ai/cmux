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
}
