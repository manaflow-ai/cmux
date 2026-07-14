import Foundation
import Testing
@testable import CmuxGit

@Suite struct GitHubPullRequestPanelServiceSchedulingTests {
    @Test func distinctContextsNeverExceedTheRefreshChainLimit() async throws {
        let fixtures = try Self.fixtures(branches: ["feature-one", "feature-two", "feature-three"])
        let probe = PullRequestRefreshSchedulingProbe()
        let limiter = RecordingPullRequestRefreshLimiter(probe: probe)
        let service = GitHubPullRequestPanelService(
            commandRunner: ConcurrencyTrackingPullRequestCommandRunner(probe: probe),
            refreshLimiter: limiter
        )

        let refreshes = fixtures.map { fixture in
            Task { try? await service.refresh(for: Self.input(fixture)) }
        }
        _ = await probe.waitForThirdAttempt()
        await probe.releaseBranchViews()
        for refresh in refreshes { _ = await refresh.value }

        #expect(await probe.maximumActiveBranchViewCount <= 2)
    }

    @Test func cancellingQueuedRefreshPreventsItsBranchViewFromStarting() async throws {
        let fixtures = try Self.fixtures(branches: ["feature-one", "feature-two", "feature-three"])
        let probe = PullRequestRefreshSchedulingProbe()
        let limiter = RecordingPullRequestRefreshLimiter(probe: probe)
        let service = GitHubPullRequestPanelService(
            commandRunner: ConcurrencyTrackingPullRequestCommandRunner(probe: probe),
            refreshLimiter: limiter
        )

        let first = Task { try? await service.refresh(for: Self.input(fixtures[0])) }
        let second = Task { try? await service.refresh(for: Self.input(fixtures[1])) }
        await probe.waitForStartedBranchCount(2)
        let third = Task { try? await service.refresh(for: Self.input(fixtures[2])) }
        let thirdAttempt = await probe.waitForThirdAttempt()

        third.cancel()
        if thirdAttempt == .queued {
            await limiter.waitForCancellationCount(1)
        }
        await probe.releaseBranchViews()
        _ = await first.value
        _ = await second.value
        _ = await third.value

        #expect(await probe.startedBranches.contains("feature-three") == false)
    }

    private static func fixtures(branches: [String]) throws -> [GitRepositoryFixture] {
        try branches.map { branch in
            let fixture = try GitRepositoryFixture()
            try fixture.writeBranch(branch)
            try fixture.writeConfig("""
            [remote "origin"]
                url = https://github.com/example/\(branch).git
            """)
            return fixture
        }
    }

    private static func input(_ fixture: GitRepositoryFixture) -> PullRequestWorkspaceInput {
        PullRequestWorkspaceInput(directory: fixture.root.path, branchHint: nil)
    }
}
