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
}
