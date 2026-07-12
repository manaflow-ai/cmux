internal import CmuxFoundation
import os

/// Process-wide counters for the tracked-status scan coordination path.
///
/// The snapshot contains aggregate counts only. It never records repository
/// paths, cache keys, or other user data, so it is safe to collect in Release
/// builds. Collection defaults off; a disabled record site performs one relaxed
/// atomic load and does not take the counter lock. Enabled counter updates hold
/// an unfair lock only long enough to increment a fixed-width integer.
public struct CmuxGitRuntimeMetricsSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: UInt64
    public let enabled: Bool
    public let rawTrackedStatusScanCount: UInt64
    public let trackedStatusCacheHitCount: UInt64
    public let trackedStatusInFlightJoinCount: UInt64
    public let trackedStatusRequestCount: UInt64

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case enabled
        case rawTrackedStatusScanCount
        case trackedStatusCacheHitCount
        case trackedStatusInFlightJoinCount
        case trackedStatusRequestCount
    }
}

/// Instantiated, thread-safe recorder for ``CmuxGitRuntimeMetricsSnapshot``.
/// ``GitMetadataService`` owns the process-wide production instance; tests may
/// inject an independent recorder.
public final class CmuxGitRuntimeMetrics: Sendable {
    private let recorder: CmuxGitRuntimeMetricsRecorder

    public init() {
        recorder = CmuxGitRuntimeMetricsRecorder()
    }

    /// Returns the current counters without changing them.
    public func snapshot() -> CmuxGitRuntimeMetricsSnapshot {
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
    public func snapshotAndReset() -> CmuxGitRuntimeMetricsSnapshot {
        recorder.snapshotAndReset()
    }

    @inline(__always)
    func recordRawTrackedStatusScan() {
        recorder.recordRawTrackedStatusScan()
    }

    @inline(__always)
    func recordTrackedStatusCacheHit() {
        recorder.recordTrackedStatusCacheHit()
    }

    @inline(__always)
    func recordTrackedStatusInFlightJoin() {
        recorder.recordTrackedStatusInFlightJoin()
    }

    @inline(__always)
    func recordTrackedStatusRequest() {
        recorder.recordTrackedStatusRequest()
    }
}

public extension GitMetadataService {
    static func runtimeMetricsSnapshot() -> CmuxGitRuntimeMetricsSnapshot {
        runtimeMetrics.snapshot()
    }

    static func resetRuntimeMetrics(enable: Bool) {
        runtimeMetrics.reset(enable: enable)
    }

    static func disableRuntimeMetrics() {
        runtimeMetrics.disable()
    }
}

/// An instance-scoped recorder keeps tests independent from live package work.
final class CmuxGitRuntimeMetricsRecorder: Sendable {
    private struct State {
        var enabled = false
        var rawTrackedStatusScanCount: UInt64 = 0
        var trackedStatusCacheHitCount: UInt64 = 0
        var trackedStatusInFlightJoinCount: UInt64 = 0
        var trackedStatusRequestCount: UInt64 = 0

        var snapshot: CmuxGitRuntimeMetricsSnapshot {
            CmuxGitRuntimeMetricsSnapshot(
                schemaVersion: 2,
                enabled: enabled,
                rawTrackedStatusScanCount: rawTrackedStatusScanCount,
                trackedStatusCacheHitCount: trackedStatusCacheHitCount,
                trackedStatusInFlightJoinCount: trackedStatusInFlightJoinCount,
                trackedStatusRequestCount: trackedStatusRequestCount
            )
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let enabled = AtomicBooleanGate(false)

    func snapshot() -> CmuxGitRuntimeMetricsSnapshot {
        state.withLock { $0.snapshot }
    }

    func reset(enable: Bool) {
        state.withLock { $0 = State(enabled: enable) }
        enabled.storeRelease(enable)
    }

    func disable() {
        enabled.storeRelease(false)
        state.withLock { $0.enabled = false }
    }

    func snapshotAndReset() -> CmuxGitRuntimeMetricsSnapshot {
        state.withLock { state in
            let snapshot = state.snapshot
            state = State(enabled: state.enabled)
            return snapshot
        }
    }

    @inline(__always)
    func recordRawTrackedStatusScan() {
        guard enabled.loadRelaxed() else { return }
        state.withLock { state in
            guard state.enabled else { return }
            state.rawTrackedStatusScanCount &+= 1
        }
    }

    @inline(__always)
    func recordTrackedStatusCacheHit() {
        guard enabled.loadRelaxed() else { return }
        state.withLock { state in
            guard state.enabled else { return }
            state.trackedStatusCacheHitCount &+= 1
        }
    }

    @inline(__always)
    func recordTrackedStatusInFlightJoin() {
        guard enabled.loadRelaxed() else { return }
        state.withLock { state in
            guard state.enabled else { return }
            state.trackedStatusInFlightJoinCount &+= 1
        }
    }

    @inline(__always)
    func recordTrackedStatusRequest() {
        guard enabled.loadRelaxed() else { return }
        state.withLock { state in
            guard state.enabled else { return }
            state.trackedStatusRequestCount &+= 1
        }
    }
}
