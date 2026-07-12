import CmuxFoundation
import Foundation
import os

nonisolated enum MobileWorkspaceObserverInvalidationMetricKind: String, Sendable {
    case workspaceGraph = "workspace_graph"
    case workspace
    case preview
    case summary
}

nonisolated struct MobileWorkspaceObserverDurationMetrics: Sendable, Equatable {
    var count = 0
    var totalMilliseconds = 0.0
    var maximumMilliseconds = 0.0
    var lastMilliseconds = 0.0

    var foundationObject: [String: Any] {
        [
            "count": count,
            "total": totalMilliseconds,
            "max": maximumMilliseconds,
            "last": lastMilliseconds,
        ]
    }
}

nonisolated struct MobileWorkspaceObserverMetricsSnapshot: Sendable, Equatable {
    let schemaVersion: Int
    let enabled: Bool
    let resetAtUnixMilliseconds: UInt64
    let invalidationsSubmitted: [String: Int]
    let batchDrains: Int
    let invalidationsDrained: Int
    let workspacesRehashed: Int
    let fullGraphRebuilds: Int
    let emits: Int
    let skips: Int
    let batchDrainDuration: MobileWorkspaceObserverDurationMetrics
    let fullGraphRebuildDuration: MobileWorkspaceObserverDurationMetrics
    let incrementalRefreshDuration: MobileWorkspaceObserverDurationMetrics
    let previewSignaturesDuration: MobileWorkspaceObserverDurationMetrics
    let summaryHashDuration: MobileWorkspaceObserverDurationMetrics

    /// Property-list-safe representation for diagnostic RPCs. It contains only
    /// aggregate counts and timings, never workspace identity or content.
    var foundationObject: [String: Any] {
        [
            "schema_version": schemaVersion,
            "enabled": enabled,
            "reset_at_unix_ms": NSNumber(value: resetAtUnixMilliseconds),
            "invalidations_submitted": invalidationsSubmitted,
            "batch_drains": batchDrains,
            "invalidations_drained": invalidationsDrained,
            "workspaces_rehashed": workspacesRehashed,
            "full_graph_rebuilds": fullGraphRebuilds,
            "emits": emits,
            "skips": skips,
            "duration_ms": [
                "batch_drain": batchDrainDuration.foundationObject,
                "full_graph_rebuild": fullGraphRebuildDuration.foundationObject,
                "incremental_refresh": incrementalRefreshDuration.foundationObject,
                "preview_signatures": previewSignaturesDuration.foundationObject,
                "summary_hash": summaryHashDuration.foundationObject,
            ],
        ]
    }
}

nonisolated struct MobileWorkspaceObserverMetricToken: Sendable, Equatable {
    fileprivate enum Operation: Sendable, Equatable {
        case batchDrain
        case fullGraphRebuild
        case incrementalRefresh
        case previewSignatures
        case summaryHash
    }

    fileprivate let operation: Operation
    fileprivate let epoch: UInt64
    fileprivate let startedAtNanoseconds: UInt64
}

/// Release-safe, process-wide proof counters for the mobile workspace observer.
/// The lock covers only fixed-size integer/timing updates and snapshots. No
/// workspace data or observer work executes while the lock is held.
nonisolated final class MobileWorkspaceObserverMetrics: @unchecked Sendable {
    static let shared = MobileWorkspaceObserverMetrics()

    private struct State {
        var epoch: UInt64
        var enabled: Bool
        var resetAtUnixMilliseconds = MobileWorkspaceObserverMetrics.unixMilliseconds()
        var workspaceGraphInvalidationsSubmitted = 0
        var workspaceInvalidationsSubmitted = 0
        var previewInvalidationsSubmitted = 0
        var summaryInvalidationsSubmitted = 0
        var batchDrains = 0
        var invalidationsDrained = 0
        var workspacesRehashed = 0
        var fullGraphRebuilds = 0
        var emits = 0
        var skips = 0
        var batchDrainDuration = MobileWorkspaceObserverDurationMetrics()
        var fullGraphRebuildDuration = MobileWorkspaceObserverDurationMetrics()
        var incrementalRefreshDuration = MobileWorkspaceObserverDurationMetrics()
        var previewSignaturesDuration = MobileWorkspaceObserverDurationMetrics()
        var summaryHashDuration = MobileWorkspaceObserverDurationMetrics()

        init(epoch: UInt64, enabled: Bool) {
            self.epoch = epoch
            self.enabled = enabled
        }
    }

    private let state: OSAllocatedUnfairLock<State>
    private let enabled: AtomicBooleanGate
    private let monotonicNanoseconds: @Sendable () -> UInt64

    init(
        enabled: Bool = false,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        let epoch: UInt64 = enabled ? 1 : 0
        self.state = OSAllocatedUnfairLock(
            initialState: State(epoch: epoch, enabled: enabled)
        )
        self.enabled = AtomicBooleanGate(enabled)
        self.monotonicNanoseconds = monotonicNanoseconds
    }

    func reset(enable: Bool) {
        state.withLock { state in
            var nextEpoch = state.epoch &+ 1
            if nextEpoch == 0 {
                nextEpoch = 1
            }
            state = State(epoch: nextEpoch, enabled: enable)
        }
        enabled.storeRelease(enable)
    }

    func disable() {
        enabled.storeRelease(false)
        state.withLock { state in
            state.enabled = false
            state.epoch &+= 1
            if state.epoch == 0 {
                state.epoch = 1
            }
        }
    }

    func snapshot() -> MobileWorkspaceObserverMetricsSnapshot {
        state.withLock { state in
            MobileWorkspaceObserverMetricsSnapshot(
                schemaVersion: 1,
                enabled: state.enabled,
                resetAtUnixMilliseconds: state.resetAtUnixMilliseconds,
                invalidationsSubmitted: [
                    MobileWorkspaceObserverInvalidationMetricKind.workspaceGraph.rawValue:
                        state.workspaceGraphInvalidationsSubmitted,
                    MobileWorkspaceObserverInvalidationMetricKind.workspace.rawValue:
                        state.workspaceInvalidationsSubmitted,
                    MobileWorkspaceObserverInvalidationMetricKind.preview.rawValue:
                        state.previewInvalidationsSubmitted,
                    MobileWorkspaceObserverInvalidationMetricKind.summary.rawValue:
                        state.summaryInvalidationsSubmitted,
                ],
                batchDrains: state.batchDrains,
                invalidationsDrained: state.invalidationsDrained,
                workspacesRehashed: state.workspacesRehashed,
                fullGraphRebuilds: state.fullGraphRebuilds,
                emits: state.emits,
                skips: state.skips,
                batchDrainDuration: state.batchDrainDuration,
                fullGraphRebuildDuration: state.fullGraphRebuildDuration,
                incrementalRefreshDuration: state.incrementalRefreshDuration,
                previewSignaturesDuration: state.previewSignaturesDuration,
                summaryHashDuration: state.summaryHashDuration
            )
        }
    }

    func recordInvalidationSubmitted(_ kind: MobileWorkspaceObserverInvalidationMetricKind) {
        guard enabled.loadRelaxed() else { return }
        state.withLock { state in
            guard state.enabled else { return }
            switch kind {
            case .workspaceGraph:
                state.workspaceGraphInvalidationsSubmitted += 1
            case .workspace:
                state.workspaceInvalidationsSubmitted += 1
            case .preview:
                state.previewInvalidationsSubmitted += 1
            case .summary:
                state.summaryInvalidationsSubmitted += 1
            }
        }
    }

    func batchDrainStarted(invalidationCount: Int) -> MobileWorkspaceObserverMetricToken? {
        guard enabled.loadRelaxed() else { return nil }
        return state.withLock { state -> MobileWorkspaceObserverMetricToken? in
            guard state.enabled else { return nil }
            state.batchDrains += 1
            state.invalidationsDrained += max(0, invalidationCount)
            return token(.batchDrain, epoch: state.epoch)
        }
    }

    func fullGraphRebuildStarted() -> MobileWorkspaceObserverMetricToken? {
        guard enabled.loadRelaxed() else { return nil }
        return state.withLock { state -> MobileWorkspaceObserverMetricToken? in
            guard state.enabled else { return nil }
            state.fullGraphRebuilds += 1
            return token(.fullGraphRebuild, epoch: state.epoch)
        }
    }

    func incrementalRefreshStarted() -> MobileWorkspaceObserverMetricToken? {
        guard enabled.loadRelaxed() else { return nil }
        return state.withLock { state -> MobileWorkspaceObserverMetricToken? in
            guard state.enabled else { return nil }
            return token(.incrementalRefresh, epoch: state.epoch)
        }
    }

    func previewSignaturesStarted() -> MobileWorkspaceObserverMetricToken? {
        guard enabled.loadRelaxed() else { return nil }
        return state.withLock { state -> MobileWorkspaceObserverMetricToken? in
            guard state.enabled else { return nil }
            return token(.previewSignatures, epoch: state.epoch)
        }
    }

    func summaryHashStarted() -> MobileWorkspaceObserverMetricToken? {
        guard enabled.loadRelaxed() else { return nil }
        return state.withLock { state -> MobileWorkspaceObserverMetricToken? in
            guard state.enabled else { return nil }
            return token(.summaryHash, epoch: state.epoch)
        }
    }

    func operationCompleted(
        _ token: MobileWorkspaceObserverMetricToken?,
        workspacesRehashed: Int = 0
    ) {
        guard enabled.loadRelaxed(), let token else { return }
        let duration = elapsedMilliseconds(since: token.startedAtNanoseconds)
        state.withLock { state in
            guard state.enabled, token.epoch == state.epoch else { return }
            state.workspacesRehashed += max(0, workspacesRehashed)
            switch token.operation {
            case .batchDrain:
                state.batchDrainDuration.record(duration)
            case .fullGraphRebuild:
                state.fullGraphRebuildDuration.record(duration)
            case .incrementalRefresh:
                state.incrementalRefreshDuration.record(duration)
            case .previewSignatures:
                state.previewSignaturesDuration.record(duration)
            case .summaryHash:
                state.summaryHashDuration.record(duration)
            }
        }
    }

    func recordEmit() {
        guard enabled.loadRelaxed() else { return }
        state.withLock { state in
            guard state.enabled else { return }
            state.emits += 1
        }
    }

    func recordSkip() {
        guard enabled.loadRelaxed() else { return }
        state.withLock { state in
            guard state.enabled else { return }
            state.skips += 1
        }
    }

    private func token(
        _ operation: MobileWorkspaceObserverMetricToken.Operation,
        epoch: UInt64
    ) -> MobileWorkspaceObserverMetricToken {
        MobileWorkspaceObserverMetricToken(
            operation: operation,
            epoch: epoch,
            startedAtNanoseconds: monotonicNanoseconds()
        )
    }

    private func elapsedMilliseconds(since start: UInt64) -> Double {
        let end = monotonicNanoseconds()
        return Double(end >= start ? end - start : 0) / 1_000_000
    }

    private static func unixMilliseconds() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
    }
}

private nonisolated extension MobileWorkspaceObserverDurationMetrics {
    mutating func record(_ milliseconds: Double) {
        count += 1
        totalMilliseconds += milliseconds
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        lastMilliseconds = milliseconds
    }
}
