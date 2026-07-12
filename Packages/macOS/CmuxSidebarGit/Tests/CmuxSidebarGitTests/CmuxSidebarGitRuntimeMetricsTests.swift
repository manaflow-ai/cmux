import Testing
@testable import CmuxSidebarGit

@Suite(.serialized)
struct CmuxSidebarGitRuntimeMetricsTests {
    @Test func recordingDefaultsDisabled() {
        let metrics = CmuxSidebarGitRuntimeMetricsRecorder()

        metrics.recordSnapshotBatchApply()
        metrics.recordMaterialChange()
        metrics.recordPullRequestSeed()
        metrics.recordPullRequestTraversal()
        metrics.recordStaleApply()

        let snapshot = metrics.snapshot()
        #expect(snapshot.schemaVersion == 1)
        #expect(!snapshot.enabled)
        #expect(snapshot.snapshotBatchApplyCount == 0)
        #expect(snapshot.materialChangeCount == 0)
        #expect(snapshot.pullRequestSeedCount == 0)
        #expect(snapshot.pullRequestTraversalCount == 0)
        #expect(snapshot.staleApplyCount == 0)
    }

    @Test func enabledResetAndAtomicTake() {
        let metrics = CmuxSidebarGitRuntimeMetricsRecorder()
        metrics.reset(enable: true)

        metrics.recordSnapshotBatchApply()
        metrics.recordMaterialChange()
        metrics.recordPullRequestSeed()
        metrics.recordPullRequestTraversal()
        metrics.recordStaleApply()

        let snapshot = metrics.snapshot()
        #expect(snapshot.enabled)
        #expect(snapshot.snapshotBatchApplyCount == 1)
        #expect(snapshot.materialChangeCount == 1)
        #expect(snapshot.pullRequestSeedCount == 1)
        #expect(snapshot.pullRequestTraversalCount == 1)
        #expect(snapshot.staleApplyCount == 1)
        #expect(metrics.snapshotAndReset() == snapshot)
        #expect(metrics.snapshot() == .zero(enabled: true))

        metrics.recordSnapshotBatchApply()
        metrics.reset(enable: true)
        #expect(metrics.snapshot() == .zero(enabled: true))
    }

    @Test func disablePreservesSnapshotAndStopsRecording() {
        let metrics = CmuxSidebarGitRuntimeMetricsRecorder()
        metrics.reset(enable: true)
        metrics.recordSnapshotBatchApply()

        metrics.disable()
        metrics.recordSnapshotBatchApply()

        let snapshot = metrics.snapshot()
        #expect(!snapshot.enabled)
        #expect(snapshot.snapshotBatchApplyCount == 1)
    }

    @Test func concurrentRecordingDoesNotLoseUpdates() async {
        let metrics = CmuxSidebarGitRuntimeMetricsRecorder()
        metrics.reset(enable: true)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    for _ in 0..<100 {
                        metrics.recordSnapshotBatchApply()
                        metrics.recordMaterialChange()
                        metrics.recordPullRequestSeed()
                        metrics.recordPullRequestTraversal()
                        metrics.recordStaleApply()
                    }
                }
            }
        }

        let snapshot = metrics.snapshot()
        #expect(snapshot.snapshotBatchApplyCount == 10_000)
        #expect(snapshot.materialChangeCount == 10_000)
        #expect(snapshot.pullRequestSeedCount == 10_000)
        #expect(snapshot.pullRequestTraversalCount == 10_000)
        #expect(snapshot.staleApplyCount == 10_000)
    }
}

private extension CmuxSidebarGitRuntimeMetricsSnapshot {
    static func zero(enabled: Bool) -> Self {
        CmuxSidebarGitRuntimeMetricsSnapshot(
            schemaVersion: 1,
            enabled: enabled,
            snapshotBatchApplyCount: 0,
            materialChangeCount: 0,
            pullRequestSeedCount: 0,
            pullRequestTraversalCount: 0,
            staleApplyCount: 0
        )
    }
}
