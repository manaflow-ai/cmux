import CmuxGit
import Foundation
import Testing
@testable import CmuxSidebarGit

@MainActor
@Suite struct SidebarGitOwnerPerformanceExerciseTests {
    @Test(.timeLimit(.minutes(1)))
    func exerciseUsesNormalRequestJoinFetchRejectAndApplySites() async throws {
        let metrics = CmuxSidebarGitRuntimeMetrics()
        metrics.reset(enable: true)

        let result = try await SidebarGitOwnerPerformanceExercise.run(
            requestCount: 4,
            runtimeMetricsRecorder: metrics
        )
        let snapshot = metrics.snapshot()

        #expect(result.requestCount == 4)
        #expect(result.singleFlightApplyCount == 1)
        #expect(result.staleApplyCountBeforeFollowUp == 0)
        #expect(result.staleFinalApplyCount == 1)
        #expect(result.staleFinalBranch == "feature/stale-b")
        #expect(snapshot.pullRequestSeedCount == 1)
        #expect(snapshot.pullRequestTraversalCount == 3)
        #expect(snapshot.pullRequestRefreshRequestCount == 6)
        #expect(snapshot.pullRequestTaskStartedCount == 3)
        #expect(snapshot.pullRequestTaskJoinedCount == 3)
        #expect(snapshot.pullRequestRepoFetchCount == 3)
        #expect(snapshot.pullRequestStaleCompletionRejectedOffMainCount == 1)
        #expect(snapshot.pullRequestMainActorApplyEnteredCount == 2)
        #expect(snapshot.pullRequestFollowUpStartedCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingGatedFetchReturnsWithoutProducingAResult() async {
        let executor = SidebarGitOwnerPerformanceExecutor()
        let resolution = await executor.resolveCandidateSeeds([
            WorkspacePullRequestCandidateSeed(
                workspaceId: UUID(),
                panelId: UUID(),
                branch: "feature/cancel-fetch",
                directory: "/isolated/owner-proof"
            ),
        ])
        let fetchTask = Task {
            await executor.fetchRepoResults(
                candidateResolution: resolution,
                cacheBySlug: [:],
                now: Date(),
                allowCachedResults: false
            )
        }

        try? await executor.waitForFetchCount(1)
        fetchTask.cancel()
        await executor.releaseNextFetch()

        #expect(await fetchTask.value.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingBadgeWaitThrowsCancellation() async {
        let host = SidebarGitOwnerPerformanceHost(branch: "feature/cancel-badge")
        let waitTask = Task { @MainActor in
            do {
                try await host.waitForBadgeApplyCount(1)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        await Task.yield()
        waitTask.cancel()
        host.updatePanelPullRequest(
            workspaceId: host.workspaceId,
            panelId: host.panelId,
            badge: SidebarPullRequestBadge(
                number: 1,
                label: "PR",
                url: URL(string: "https://github.invalid/cmux/owner-proof/pull/1")!,
                status: .open,
                branch: host.branch
            )
        )

        #expect(await waitTask.value)
    }
}
