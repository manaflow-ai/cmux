import os

/// Process-wide counters for sidebar Git snapshot and pull-request work.
///
/// The snapshot contains aggregate counts only. It never records directories,
/// branches, workspace identifiers, pull-request data, or diagnostic reasons,
/// so it is safe to collect in Release builds. Collection defaults off; a
/// disabled record site performs one relaxed atomic load and does not take the
/// counter lock. Enabled updates hold an unfair lock only long enough to
/// increment a fixed-width integer.
public struct CmuxSidebarGitRuntimeMetricsSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: UInt64
    public let enabled: Bool
    public let snapshotBatchApplyCount: UInt64
    public let materialChangeCount: UInt64
    public let pullRequestSeedCount: UInt64
    public let pullRequestTraversalCount: UInt64
    public let staleApplyCount: UInt64

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case enabled
        case snapshotBatchApplyCount
        case materialChangeCount
        case pullRequestSeedCount
        case pullRequestTraversalCount
        case staleApplyCount
    }
}

/// Instantiated, thread-safe recorder for
/// ``CmuxSidebarGitRuntimeMetricsSnapshot``. ``SidebarGitMetadataService`` owns
/// the process-wide production instance; tests may inject an independent one.
public final class CmuxSidebarGitRuntimeMetrics: Sendable {
    private let recorder: CmuxSidebarGitRuntimeMetricsRecorder

    public init() {
        recorder = CmuxSidebarGitRuntimeMetricsRecorder()
    }

    /// Returns the current counters without changing them.
    public func snapshot() -> CmuxSidebarGitRuntimeMetricsSnapshot {
        recorder.snapshot()
    }

    /// Clears all counters and selects whether subsequent events are recorded.
    public func reset(enable: Bool) {
        recorder.reset(enable: enable)
    }

    /// Stops recording while preserving the counters already collected.
    public func disable() {
        recorder.disable()
    }

    /// Returns the current counters and clears them in the same critical section.
    public func snapshotAndReset() -> CmuxSidebarGitRuntimeMetricsSnapshot {
        recorder.snapshotAndReset()
    }

    @inline(__always)
    func recordSnapshotBatchApply() {
        recorder.recordSnapshotBatchApply()
    }

    @inline(__always)
    func recordMaterialChange() {
        recorder.recordMaterialChange()
    }

    @inline(__always)
    func recordPullRequestSeed() {
        recorder.recordPullRequestSeed()
    }

    @inline(__always)
    func recordPullRequestTraversal() {
        recorder.recordPullRequestTraversal()
    }

    @inline(__always)
    func recordStaleApply() {
        recorder.recordStaleApply()
    }
}

public extension SidebarGitMetadataService {
    static func runtimeMetricsSnapshot() -> CmuxSidebarGitRuntimeMetricsSnapshot {
        runtimeMetrics.snapshot()
    }

    static func resetRuntimeMetrics(enable: Bool) {
        runtimeMetrics.reset(enable: enable)
    }

    static func disableRuntimeMetrics() {
        runtimeMetrics.disable()
    }
}

extension SidebarGitMetadataService {
    static func recordSnapshotBatchApply() {
        runtimeMetrics.recordSnapshotBatchApply()
    }

    static func recordMaterialChange() {
        runtimeMetrics.recordMaterialChange()
    }

    static func recordPullRequestSeed() {
        runtimeMetrics.recordPullRequestSeed()
    }

    static func recordPullRequestTraversal() {
        runtimeMetrics.recordPullRequestTraversal()
    }

    static func recordStaleApply() {
        runtimeMetrics.recordStaleApply()
    }
}

/// An instance-scoped recorder keeps tests independent from live package work.
final class CmuxSidebarGitRuntimeMetricsRecorder: Sendable {
    private struct State {
        var enabled = false
        var snapshotBatchApplyCount: UInt64 = 0
        var materialChangeCount: UInt64 = 0
        var pullRequestSeedCount: UInt64 = 0
        var pullRequestTraversalCount: UInt64 = 0
        var staleApplyCount: UInt64 = 0

        var snapshot: CmuxSidebarGitRuntimeMetricsSnapshot {
            CmuxSidebarGitRuntimeMetricsSnapshot(
                schemaVersion: 1,
                enabled: enabled,
                snapshotBatchApplyCount: snapshotBatchApplyCount,
                materialChangeCount: materialChangeCount,
                pullRequestSeedCount: pullRequestSeedCount,
                pullRequestTraversalCount: pullRequestTraversalCount,
                staleApplyCount: staleApplyCount
            )
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func snapshot() -> CmuxSidebarGitRuntimeMetricsSnapshot {
        state.withLock { $0.snapshot }
    }

    func reset(enable: Bool) {
        state.withLock { $0 = State(enabled: enable) }
    }

    func disable() {
        state.withLock { $0.enabled = false }
    }

    func snapshotAndReset() -> CmuxSidebarGitRuntimeMetricsSnapshot {
        state.withLock { state in
            let snapshot = state.snapshot
            state = State(enabled: state.enabled)
            return snapshot
        }
    }

    @inline(__always)
    func recordSnapshotBatchApply() {
        state.withLock { state in
            guard state.enabled else { return }
            state.snapshotBatchApplyCount &+= 1
        }
    }

    @inline(__always)
    func recordMaterialChange() {
        state.withLock { state in
            guard state.enabled else { return }
            state.materialChangeCount &+= 1
        }
    }

    @inline(__always)
    func recordPullRequestSeed() {
        state.withLock { state in
            guard state.enabled else { return }
            state.pullRequestSeedCount &+= 1
        }
    }

    @inline(__always)
    func recordPullRequestTraversal() {
        state.withLock { state in
            guard state.enabled else { return }
            state.pullRequestTraversalCount &+= 1
        }
    }

    @inline(__always)
    func recordStaleApply() {
        state.withLock { state in
            guard state.enabled else { return }
            state.staleApplyCount &+= 1
        }
    }
}
