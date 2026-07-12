import CmuxFoundation
import Foundation
import os

nonisolated struct ProcessPerformanceDurationMetrics: Sendable, Equatable {
    var count = 0
    var totalMilliseconds = 0.0
    var maximumMilliseconds = 0.0
    var lastMilliseconds = 0.0
}

nonisolated struct ProcessPerformanceReuseMetrics: Sendable, Equatable {
    var cache = 0
    var inFlight = 0
}

nonisolated struct ProcessPerformanceSnapshotCaptureMetrics: Sendable, Equatable {
    var captureStarted = 0
    var captureCompleted = 0
    var inFlight = 0
    var maximumInFlight = 0
    var lastGeneration: UInt64 = 0
    var duration = ProcessPerformanceDurationMetrics()
}

nonisolated struct ProcessPerformanceOperationMetrics: Sendable, Equatable {
    var started = 0
    var completed = 0
    var inputCount = 0
    var outputCount = 0
    var duration = ProcessPerformanceDurationMetrics()
}

nonisolated struct ProcessPerformanceGenerationMetrics: Sendable, Equatable {
    var requirementsRawValue: UInt8 = 0
    var started = 0
    var completed = 0
    var processCount = 0
    var backend = "pending"
    var processLaunches = 0
    var duration = ProcessPerformanceDurationMetrics()
}

nonisolated struct ProcessPerformanceLsofMetrics: Sendable, Equatable {
    // Kept under the legacy `lsof` RPC key for schema compatibility. The
    // backend field identifies that these counters now measure libproc scans.
    var started = 0
    var completed = 0
    var inFlight = 0
    var maximumInFlight = 0
    var pidCount = 0
    var coalescedRequests = 0
    var backendCounts: [String: Int] = [:]
    var processLaunches = 0
    var reuse = ProcessPerformanceReuseMetrics()
    var duration = ProcessPerformanceDurationMetrics()
}

nonisolated struct ProcessPerformanceMetricsSnapshot: Sendable, Equatable {
    let enabled: Bool
    let resetAtUnixMilliseconds: UInt64
    let processSnapshots: ProcessPerformanceSnapshotCaptureMetrics
    let generations: [UInt64: ProcessPerformanceGenerationMetrics]
    let requestCountsByConsumer: [String: Int]
    let consumerGenerationReuse: [String: [UInt64: ProcessPerformanceReuseMetrics]]
    let lsof: ProcessPerformanceLsofMetrics
    let staleRejections: [String: Int]
    let operations: [String: ProcessPerformanceOperationMetrics]

    var foundationObject: [String: Any] {
        return [
            "schema_version": 2,
            "enabled": enabled,
            "reset_at_unix_ms": NSNumber(value: resetAtUnixMilliseconds),
            "process_snapshots": [
                "capture_started": processSnapshots.captureStarted,
                "capture_completed": processSnapshots.captureCompleted,
                "in_flight": processSnapshots.inFlight,
                "max_in_flight": processSnapshots.maximumInFlight,
                "last_generation": NSNumber(value: processSnapshots.lastGeneration),
                "duration_ms": processSnapshots.duration.foundationObject,
                "generations": Dictionary(uniqueKeysWithValues: generations.map { generation, metrics in
                    (String(generation), metrics.foundationObject)
                }),
            ],
            "consumer_generation_reuse": consumerGenerationReuse.mapValues { generations in
                Dictionary(uniqueKeysWithValues: generations.map { generation, metrics in
                    (String(generation), metrics.foundationObject)
                })
            },
            "request_counts_by_consumer": requestCountsByConsumer,
            "lsof": lsof.foundationObject,
            "stale_rejections": staleRejections,
            "operations": operations.mapValues(\.foundationObject),
        ]
    }
}

private nonisolated extension ProcessPerformanceDurationMetrics {
    var foundationObject: [String: Any] {
        [
            "count": count,
            "total": totalMilliseconds,
            "max": maximumMilliseconds,
            "last": lastMilliseconds,
        ]
    }
}

private nonisolated extension ProcessPerformanceReuseMetrics {
    var foundationObject: [String: Any] {
        ["cache": cache, "in_flight": inFlight]
    }
}

private nonisolated extension ProcessPerformanceGenerationMetrics {
    var foundationObject: [String: Any] {
        [
            "requirements_raw_value": Int(requirementsRawValue),
            "started": started,
            "completed": completed,
            "process_count": processCount,
            "backend": backend,
            "process_launches": processLaunches,
            "duration_ms": duration.foundationObject,
        ]
    }
}

private nonisolated extension ProcessPerformanceLsofMetrics {
    var foundationObject: [String: Any] {
        let backend: String
        if backendCounts.isEmpty {
            backend = "none"
        } else if backendCounts.count == 1 {
            backend = backendCounts.keys.first ?? "none"
        } else {
            backend = "mixed"
        }
        return [
            "backend": backend,
            "backend_counts": backendCounts,
            "process_launches": processLaunches,
            "started": started,
            "completed": completed,
            "in_flight": inFlight,
            "max_in_flight": maximumInFlight,
            "pid_count": pidCount,
            "coalesced_requests": coalescedRequests,
            "reuse": reuse.foundationObject,
            "duration_ms": duration.foundationObject,
        ]
    }
}

private nonisolated extension ProcessPerformanceOperationMetrics {
    var foundationObject: [String: Any] {
        [
            "started": started,
            "completed": completed,
            "input_count": inputCount,
            "output_count": outputCount,
            "duration_ms": duration.foundationObject,
        ]
    }
}

nonisolated struct ProcessPerformanceMetricToken: Sendable {
    fileprivate let key: String
    fileprivate let epoch: UInt64
    fileprivate let startedAtNanoseconds: UInt64?
    fileprivate let inputCount: Int
}

/// Opt-in, process-wide counters for proving process enumeration is shared and
/// absent from the interactive typing path in an optimized Release build. The
/// counters are disabled by default. The lock protects only small integer
/// updates and JSON snapshots; no process work or UI mutation runs in its
/// critical section.
nonisolated final class ProcessPerformanceMetrics: @unchecked Sendable {
    static let shared = ProcessPerformanceMetrics()

    private struct State {
        var epoch: UInt64
        var enabled: Bool
        var synchronousCaptureGeneration: UInt64 = 0
        var resetAtUnixMilliseconds = ProcessPerformanceMetrics.unixMilliseconds()
        var processSnapshots = ProcessPerformanceSnapshotCaptureMetrics()
        var generations: [UInt64: ProcessPerformanceGenerationMetrics] = [:]
        var requestCountsByConsumer: [String: Int] = [:]
        var consumerGenerationReuse: [String: [UInt64: ProcessPerformanceReuseMetrics]] = [:]
        var lsof = ProcessPerformanceLsofMetrics()
        var staleRejections: [String: Int] = [:]
        var operations: [String: ProcessPerformanceOperationMetrics] = [:]

        init(epoch: UInt64 = 0, enabled: Bool = false) {
            self.epoch = epoch
            self.enabled = enabled
        }
    }

    private let state: OSAllocatedUnfairLock<State>
    private let enabled: AtomicBooleanGate
    private let monotonicNanoseconds: @Sendable () -> UInt64

    init(
        enabled: Bool = _isDebugAssertConfiguration(),
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        state = OSAllocatedUnfairLock(initialState: State(enabled: enabled))
        self.enabled = AtomicBooleanGate(enabled)
        self.monotonicNanoseconds = monotonicNanoseconds
    }

    func reset(enable: Bool = true) {
        state.withLock { state in
            state = State(epoch: state.epoch &+ 1, enabled: enable)
        }
        enabled.storeRelease(enable)
    }

    func disable() {
        enabled.storeRelease(false)
        state.withLock { $0.enabled = false }
    }

    func snapshot() -> ProcessPerformanceMetricsSnapshot {
        state.withLock { state in
            ProcessPerformanceMetricsSnapshot(
                enabled: state.enabled,
                resetAtUnixMilliseconds: state.resetAtUnixMilliseconds,
                processSnapshots: state.processSnapshots,
                generations: state.generations,
                requestCountsByConsumer: state.requestCountsByConsumer,
                consumerGenerationReuse: state.consumerGenerationReuse,
                lsof: state.lsof,
                staleRejections: state.staleRejections,
                operations: state.operations
            )
        }
    }

    func recordProcessSnapshotRequest(consumer: ProcessSnapshotConsumer) {
        guard enabled.loadRelaxed() else { return }
        state.withLock { state in
            guard state.enabled else { return }
            state.requestCountsByConsumer[consumer.rawValue, default: 0] += 1
        }
    }

    func nextSynchronousCaptureGeneration() -> UInt64 {
        guard enabled.loadRelaxed() else { return 0 }
        return state.withLock { state -> UInt64 in
            guard state.enabled else { return 0 }
            state.synchronousCaptureGeneration &+= 1
            return (UInt64(1) << 63) | state.synchronousCaptureGeneration
        }
    }

    func processSnapshotCaptureStarted(
        generation: UInt64,
        requirementsRawValue: UInt8
    ) -> ProcessPerformanceMetricToken {
        guard enabled.loadRelaxed() else {
            return disabledToken(key: String(generation), inputCount: 0)
        }
        return state.withLock { state in
            guard state.enabled else {
                return disabledToken(key: String(generation), inputCount: 0)
            }
            state.processSnapshots.captureStarted += 1
            state.processSnapshots.inFlight += 1
            state.processSnapshots.maximumInFlight = max(
                state.processSnapshots.maximumInFlight,
                state.processSnapshots.inFlight
            )
            state.processSnapshots.lastGeneration = generation
            state.generations[generation, default: ProcessPerformanceGenerationMetrics()]
                .requirementsRawValue = requirementsRawValue
            state.generations[generation, default: ProcessPerformanceGenerationMetrics()].started += 1
            return token(
                key: String(generation),
                inputCount: 0,
                epoch: state.epoch
            )
        }
    }

    func processSnapshotCaptureCompleted(
        _ token: ProcessPerformanceMetricToken,
        generation: UInt64,
        processCount: Int,
        proof: ProcessPerformanceCaptureProof = .libproc
    ) {
        guard enabled.loadRelaxed(), let startedAt = token.startedAtNanoseconds else { return }
        let duration = elapsedMilliseconds(since: startedAt)
        return state.withLock { state in
            guard state.enabled, token.epoch == state.epoch else { return }
            state.processSnapshots.captureCompleted += 1
            state.processSnapshots.inFlight = max(0, state.processSnapshots.inFlight - 1)
            state.processSnapshots.duration.record(duration)
            state.generations[generation, default: ProcessPerformanceGenerationMetrics()].completed += 1
            state.generations[generation, default: ProcessPerformanceGenerationMetrics()].processCount = processCount
            state.generations[generation, default: ProcessPerformanceGenerationMetrics()].backend =
                proof.backend.rawValue
            state.generations[generation, default: ProcessPerformanceGenerationMetrics()].processLaunches +=
                max(0, proof.processLaunchCount)
            state.generations[generation, default: ProcessPerformanceGenerationMetrics()].duration.record(duration)
        }
    }

    func recordProcessSnapshotReuse(
        consumer: ProcessSnapshotConsumer,
        generation: UInt64,
        source: ProcessSnapshotReuseSource,
        token: ProcessPerformanceMetricToken
    ) {
        guard enabled.loadRelaxed(), token.startedAtNanoseconds != nil else { return }
        return state.withLock { state in
            guard state.enabled, token.epoch == state.epoch else { return }
            var byGeneration = state.consumerGenerationReuse[consumer.rawValue, default: [:]]
            var metrics = byGeneration[generation, default: ProcessPerformanceReuseMetrics()]
            switch source {
            case .cache: metrics.cache += 1
            case .inFlight: metrics.inFlight += 1
            }
            byGeneration[generation] = metrics
            state.consumerGenerationReuse[consumer.rawValue] = byGeneration
        }
    }

    func lsofStarted(pidCount: Int) -> ProcessPerformanceMetricToken {
        guard enabled.loadRelaxed() else {
            return disabledToken(key: "lsof", inputCount: pidCount)
        }
        return state.withLock { state in
            guard state.enabled else {
                return disabledToken(key: "lsof", inputCount: pidCount)
            }
            state.lsof.started += 1
            state.lsof.inFlight += 1
            state.lsof.maximumInFlight = max(state.lsof.maximumInFlight, state.lsof.inFlight)
            state.lsof.pidCount += max(0, pidCount)
            return token(
                key: "lsof",
                inputCount: pidCount,
                epoch: state.epoch
            )
        }
    }

    func lsofCompleted(
        _ token: ProcessPerformanceMetricToken,
        proof: ProcessPerformanceCaptureProof = .libproc
    ) {
        guard enabled.loadRelaxed(), let startedAt = token.startedAtNanoseconds else { return }
        let duration = elapsedMilliseconds(since: startedAt)
        state.withLock { state in
            guard state.enabled, token.epoch == state.epoch else { return }
            state.lsof.completed += 1
            state.lsof.inFlight = max(0, state.lsof.inFlight - 1)
            state.lsof.backendCounts[proof.backend.rawValue, default: 0] += 1
            state.lsof.processLaunches += max(0, proof.processLaunchCount)
            state.lsof.duration.record(duration)
        }
    }

    func recordLsofReuse(
        _ source: ProcessLsofReuseSource,
        token: ProcessPerformanceMetricToken
    ) {
        guard enabled.loadRelaxed(), token.startedAtNanoseconds != nil else { return }
        state.withLock { state in
            guard state.enabled, token.epoch == state.epoch else { return }
            switch source {
            case .cache: state.lsof.reuse.cache += 1
            case .inFlight: state.lsof.reuse.inFlight += 1
            }
        }
    }

    func recordLsofCoalescedRequest(token: ProcessPerformanceMetricToken) {
        guard enabled.loadRelaxed(), token.startedAtNanoseconds != nil else { return }
        state.withLock { state in
            guard state.enabled, token.epoch == state.epoch else { return }
            state.lsof.coalescedRequests += 1
        }
    }

    func recordStaleRejection(_ rejection: ProcessStaleRejection) {
        guard enabled.loadRelaxed() else { return }
        state.withLock { state in
            guard state.enabled else { return }
            state.staleRejections[rejection.rawValue, default: 0] += 1
        }
    }

    func operationStarted(
        _ operation: ProcessMeasuredOperation,
        inputCount: Int
    ) -> ProcessPerformanceMetricToken {
        guard enabled.loadRelaxed() else {
            return disabledToken(key: operation.rawValue, inputCount: inputCount)
        }
        return state.withLock { state in
            guard state.enabled else {
                return disabledToken(key: operation.rawValue, inputCount: inputCount)
            }
            state.operations[operation.rawValue, default: ProcessPerformanceOperationMetrics()].started += 1
            state.operations[operation.rawValue, default: ProcessPerformanceOperationMetrics()].inputCount += max(0, inputCount)
            return token(
                key: operation.rawValue,
                inputCount: inputCount,
                epoch: state.epoch
            )
        }
    }

    func operationCompleted(
        _ token: ProcessPerformanceMetricToken,
        outputCount: Int
    ) {
        guard enabled.loadRelaxed(), let startedAt = token.startedAtNanoseconds else { return }
        let duration = elapsedMilliseconds(since: startedAt)
        state.withLock { state in
            guard state.enabled, token.epoch == state.epoch else { return }
            state.operations[token.key, default: ProcessPerformanceOperationMetrics()].completed += 1
            state.operations[token.key, default: ProcessPerformanceOperationMetrics()].outputCount += max(0, outputCount)
            state.operations[token.key, default: ProcessPerformanceOperationMetrics()].duration.record(duration)
        }
    }

    private func token(
        key: String,
        inputCount: Int,
        epoch: UInt64
    ) -> ProcessPerformanceMetricToken {
        ProcessPerformanceMetricToken(
            key: key,
            epoch: epoch,
            startedAtNanoseconds: monotonicNanoseconds(),
            inputCount: inputCount
        )
    }

    private func disabledToken(key: String, inputCount: Int) -> ProcessPerformanceMetricToken {
        ProcessPerformanceMetricToken(
            key: key,
            epoch: 0,
            startedAtNanoseconds: nil,
            inputCount: inputCount
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

private nonisolated extension ProcessPerformanceDurationMetrics {
    mutating func record(_ milliseconds: Double) {
        count += 1
        totalMilliseconds += milliseconds
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        lastMilliseconds = milliseconds
    }
}
