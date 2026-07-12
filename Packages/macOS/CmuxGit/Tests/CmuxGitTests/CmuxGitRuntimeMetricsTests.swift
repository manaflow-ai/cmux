import Testing
@testable import CmuxGit

@Suite(.serialized)
struct CmuxGitRuntimeMetricsTests {
    @Test func recordingDefaultsDisabled() {
        let metrics = CmuxGitRuntimeMetricsRecorder()

        metrics.recordRawTrackedStatusScan()
        metrics.recordTrackedStatusCacheHit()
        metrics.recordTrackedStatusInFlightJoin()

        let snapshot = metrics.snapshot()
        #expect(snapshot.schemaVersion == 1)
        #expect(!snapshot.enabled)
        #expect(snapshot.rawTrackedStatusScanCount == 0)
        #expect(snapshot.trackedStatusCacheHitCount == 0)
        #expect(snapshot.trackedStatusInFlightJoinCount == 0)
    }

    @Test func enabledResetAndAtomicTake() {
        let metrics = CmuxGitRuntimeMetricsRecorder()
        metrics.reset(enable: true)

        metrics.recordRawTrackedStatusScan()
        metrics.recordTrackedStatusCacheHit()
        metrics.recordTrackedStatusInFlightJoin()

        let snapshot = metrics.snapshot()
        #expect(snapshot.enabled)
        #expect(snapshot.rawTrackedStatusScanCount == 1)
        #expect(snapshot.trackedStatusCacheHitCount == 1)
        #expect(snapshot.trackedStatusInFlightJoinCount == 1)
        #expect(metrics.snapshotAndReset() == snapshot)
        #expect(metrics.snapshot() == .zero(enabled: true))

        metrics.recordRawTrackedStatusScan()
        metrics.reset(enable: true)
        #expect(metrics.snapshot() == .zero(enabled: true))
    }

    @Test func disablePreservesSnapshotAndStopsRecording() {
        let metrics = CmuxGitRuntimeMetricsRecorder()
        metrics.reset(enable: true)
        metrics.recordRawTrackedStatusScan()

        metrics.disable()
        metrics.recordRawTrackedStatusScan()

        let snapshot = metrics.snapshot()
        #expect(!snapshot.enabled)
        #expect(snapshot.rawTrackedStatusScanCount == 1)
    }

    @Test func concurrentRecordingDoesNotLoseUpdates() async {
        let metrics = CmuxGitRuntimeMetricsRecorder()
        metrics.reset(enable: true)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    for _ in 0..<100 {
                        metrics.recordRawTrackedStatusScan()
                        metrics.recordTrackedStatusCacheHit()
                        metrics.recordTrackedStatusInFlightJoin()
                    }
                }
            }
        }

        let snapshot = metrics.snapshot()
        #expect(snapshot.rawTrackedStatusScanCount == 10_000)
        #expect(snapshot.trackedStatusCacheHitCount == 10_000)
        #expect(snapshot.trackedStatusInFlightJoinCount == 10_000)
    }
}

private extension CmuxGitRuntimeMetricsSnapshot {
    static func zero(enabled: Bool) -> Self {
        CmuxGitRuntimeMetricsSnapshot(
            schemaVersion: 1,
            enabled: enabled,
            rawTrackedStatusScanCount: 0,
            trackedStatusCacheHitCount: 0,
            trackedStatusInFlightJoinCount: 0
        )
    }
}
