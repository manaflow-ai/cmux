import Testing
@testable import CmuxGit

@Suite struct GitOwnerPerformanceExerciseTests {
    @Test(.timeLimit(.minutes(1)))
    func exerciseUsesNormalSingleFlightAndRawScanRecordSites() async throws {
        let metrics = CmuxGitRuntimeMetrics()
        metrics.reset(enable: true)

        let result = try await GitOwnerPerformanceExercise.run(
            requestCount: 4,
            runtimeMetricsRecorder: metrics
        )
        let snapshot = metrics.snapshot()

        #expect(result.requestCount == 4)
        #expect(result.completedSnapshotCount == 4)
        #expect(result.allSnapshotsMatched)
        #expect(result.allWaitersRegistered)
        #expect(snapshot.trackedStatusRequestCount == 4)
        #expect(snapshot.rawTrackedStatusScanCount == 1)
        #expect(snapshot.trackedStatusCacheHitCount == 0)
        #expect(snapshot.trackedStatusInFlightJoinCount == 3)
    }
}
