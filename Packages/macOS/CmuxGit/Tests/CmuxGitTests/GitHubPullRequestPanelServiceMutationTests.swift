import Foundation
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

    @Test func refreshLooksUpTheResolvedBranchWithinTheResolvedRepository() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("feature/fork")
        try fixture.writeConfig("""
        [remote "origin"]
            url = https://github.com/example/repo.git
        """)
        let runner = RecordingPullRequestCommandRunner()
        let service = GitHubPullRequestPanelService(commandRunner: runner)

        do {
            _ = try await service.refresh(for: PullRequestWorkspaceInput(
                directory: fixture.root.path,
                branchHint: "stale-branch-hint"
            ))
            Issue.record("Expected the empty recorded response to be rejected")
        } catch let error as PullRequestPanelServiceError {
            #expect(error == .invalidResponse)
        }

        #expect(await runner.lastArguments == [
            "pr", "view", "feature/fork", "--repo", "example/repo", "--json",
            "number,title,state,url,statusCheckRollup,updatedAt,isDraft,mergeable,reviewDecision,mergeStateStatus,autoMergeRequest,baseRefName,headRefName,baseRefOid,headRefOid",
        ])
    }

    @Test func mismatchedNumericBranchResponseStopsBeforeDetailRequests() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("123")
        try fixture.writeConfig("""
        [remote "origin"]
            url = https://github.com/example/repo.git
        """)
        let loader = PullRequestFixtureLoader()
        var response = try #require(
            JSONSerialization.jsonObject(with: loader.data(named: "pull-request-view"))
                as? [String: Any]
        )
        response["headRefName"] = "unrelated-branch"
        let responseData = try JSONSerialization.data(withJSONObject: response)
        let runner = RecordingPullRequestCommandRunner(
            outputs: [try #require(String(data: responseData, encoding: .utf8))]
        )
        let service = GitHubPullRequestPanelService(commandRunner: runner)

        do {
            _ = try await service.refresh(for: PullRequestWorkspaceInput(
                directory: fixture.root.path,
                branchHint: "123"
            ))
            Issue.record("Expected the mismatched pull request to be rejected")
        } catch let error as PullRequestPanelServiceError {
            #expect(error == .refreshFailed)
        }

        #expect(await runner.invocationArguments.count == 1)
        #expect(await runner.lastArguments.starts(with: [
            "pr", "view", "123", "--repo", "example/repo",
        ]))
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

    @Test func subdirectoriesOfOneContextShareTheSameRefreshTask() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("feat-pr-sidebar")
        try fixture.writeConfig("""
        [remote "origin"]
            url = https://github.com/example/repo.git
        """)
        let firstDirectory = fixture.root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = fixture.root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let loader = PullRequestFixtureLoader()
        let runner = SuspendingPullRequestCommandRunner(
            pullRequestViewOutput: try #require(String(
                data: loader.data(named: "pull-request-view"),
                encoding: .utf8
            )),
            checksOutput: try #require(String(
                data: loader.data(named: "pull-request-checks"),
                encoding: .utf8
            )),
            commentsOutput: try #require(String(
                data: loader.data(named: "pull-request-comments"),
                encoding: .utf8
            )),
            mergeSettingsOutput: try #require(String(
                data: loader.data(named: "repository-merge-settings"),
                encoding: .utf8
            ))
        )
        let service = GitHubPullRequestPanelService(commandRunner: runner)
        let firstInput = PullRequestWorkspaceInput(
            directory: firstDirectory.path,
            branchHint: "feat-pr-sidebar"
        )
        let secondInput = PullRequestWorkspaceInput(
            directory: secondDirectory.path,
            branchHint: "feat-pr-sidebar"
        )

        let firstRefresh = Task { try await service.refresh(for: firstInput) }
        await runner.waitForBranchViewInvocationCount(1)
        let secondRefresh = Task { try await service.refresh(for: secondInput) }
        await Task.yield()
        #expect(await runner.branchViewInvocationCount == 1)
        await runner.resumeFirstBranchView()

        let firstContent = try await firstRefresh.value
        let secondContent = try await secondRefresh.value
        #expect(firstContent == secondContent)
        #expect(await runner.branchViewInvocationCount == 1)
    }
}
