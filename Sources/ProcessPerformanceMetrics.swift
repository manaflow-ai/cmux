import Foundation

nonisolated enum ProcessSnapshotConsumer: String, Sendable {
    case memoryGuardrail = "memory_guardrail"
    case portScannerAgent = "port_scanner.agent"
    case portScannerPanel = "port_scanner.panel"
    case processDetectedResume = "process_detected_resume"
    case sentry = "sentry"
    case sharedLiveAgentIndex = "shared_live_agent_index"
    case systemTop = "system_top"
    case unspecified
}

nonisolated enum ProcessStaleRejection: String, Sendable {
    case portAgentAcknowledgement = "port_agent_acknowledgement"
    case portAgentRevision = "port_agent_revision"
    case portPanelRevision = "port_panel_revision"
}

#if DEBUG
import os

nonisolated enum ProcessSnapshotReuseSource: String, Sendable {
    case cache
    case inFlight = "in_flight"
}

nonisolated enum ProcessLsofReuseSource: String, Sendable {
    case cache
    case inFlight = "in_flight"
}

nonisolated enum ProcessMeasuredOperation: String, Sendable {
    case portApply = "port.apply"
    case portFilter = "port.filter"
    case restorableApply = "restorable.apply"
    case restorableLoad = "restorable.load"
    case vaultFilter = "vault.filter"
}

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
    var reuse = ProcessPerformanceReuseMetrics()
    var duration = ProcessPerformanceDurationMetrics()
}

nonisolated struct ProcessPerformanceMetricsSnapshot: Sendable, Equatable {
    let resetAtUnixMilliseconds: UInt64
    let processSnapshots: ProcessPerformanceSnapshotCaptureMetrics
    let generations: [UInt64: ProcessPerformanceGenerationMetrics]
    let requestCountsByConsumer: [String: Int]
    let consumerGenerationReuse: [String: [UInt64: ProcessPerformanceReuseMetrics]]
    let lsof: ProcessPerformanceLsofMetrics
    let staleRejections: [String: Int]
    let operations: [String: ProcessPerformanceOperationMetrics]

    var foundationObject: [String: Any] {
        [
            "schema_version": 1,
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
            "duration_ms": duration.foundationObject,
        ]
    }
}

private nonisolated extension ProcessPerformanceLsofMetrics {
    var foundationObject: [String: Any] {
        [
            "backend": "libproc",
            "process_launches": 0,
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
    fileprivate let startedAtNanoseconds: UInt64
    fileprivate let inputCount: Int
}

/// DEBUG-only, process-wide counters for proving process enumeration is shared
/// and absent from the interactive typing path. The lock protects only small
/// integer updates and JSON snapshots; no process work or UI mutation runs in
/// its critical section.
nonisolated final class ProcessPerformanceMetrics: @unchecked Sendable {
    static let shared = ProcessPerformanceMetrics()

    private struct State {
        var epoch: UInt64
        var synchronousCaptureGeneration: UInt64 = 0
        var resetAtUnixMilliseconds = ProcessPerformanceMetrics.unixMilliseconds()
        var processSnapshots = ProcessPerformanceSnapshotCaptureMetrics()
        var generations: [UInt64: ProcessPerformanceGenerationMetrics] = [:]
        var requestCountsByConsumer: [String: Int] = [:]
        var consumerGenerationReuse: [String: [UInt64: ProcessPerformanceReuseMetrics]] = [:]
        var lsof = ProcessPerformanceLsofMetrics()
        var staleRejections: [String: Int] = [:]
        var operations: [String: ProcessPerformanceOperationMetrics] = [:]

        init(epoch: UInt64 = 0) {
            self.epoch = epoch
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func reset() {
        state.withLock { state in
            state = State(epoch: state.epoch &+ 1)
        }
    }

    func snapshot() -> ProcessPerformanceMetricsSnapshot {
        state.withLock { state in
            ProcessPerformanceMetricsSnapshot(
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
        state.withLock { state in
            state.requestCountsByConsumer[consumer.rawValue, default: 0] += 1
        }
    }

    func nextSynchronousCaptureGeneration() -> UInt64 {
        state.withLock { state in
            state.synchronousCaptureGeneration &+= 1
            return (UInt64(1) << 63) | state.synchronousCaptureGeneration
        }
    }

    func processSnapshotCaptureStarted(
        generation: UInt64,
        requirementsRawValue: UInt8
    ) -> ProcessPerformanceMetricToken {
        state.withLock { state in
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
            return Self.token(
                key: String(generation),
                inputCount: 0,
                epoch: state.epoch
            )
        }
    }

    func processSnapshotCaptureCompleted(
        _ token: ProcessPerformanceMetricToken,
        generation: UInt64,
        processCount: Int
    ) {
        let duration = Self.elapsedMilliseconds(since: token.startedAtNanoseconds)
        state.withLock { state in
            guard token.epoch == state.epoch else { return }
            state.processSnapshots.captureCompleted += 1
            state.processSnapshots.inFlight = max(0, state.processSnapshots.inFlight - 1)
            state.processSnapshots.duration.record(duration)
            state.generations[generation, default: ProcessPerformanceGenerationMetrics()].completed += 1
            state.generations[generation, default: ProcessPerformanceGenerationMetrics()].processCount = processCount
            state.generations[generation, default: ProcessPerformanceGenerationMetrics()].duration.record(duration)
        }
    }

    func recordProcessSnapshotReuse(
        consumer: ProcessSnapshotConsumer,
        generation: UInt64,
        source: ProcessSnapshotReuseSource,
        token: ProcessPerformanceMetricToken
    ) {
        state.withLock { state in
            guard token.epoch == state.epoch else { return }
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
        state.withLock { state in
            state.lsof.started += 1
            state.lsof.inFlight += 1
            state.lsof.maximumInFlight = max(state.lsof.maximumInFlight, state.lsof.inFlight)
            state.lsof.pidCount += max(0, pidCount)
            return Self.token(
                key: "lsof",
                inputCount: pidCount,
                epoch: state.epoch
            )
        }
    }

    func lsofCompleted(_ token: ProcessPerformanceMetricToken) {
        let duration = Self.elapsedMilliseconds(since: token.startedAtNanoseconds)
        state.withLock { state in
            guard token.epoch == state.epoch else { return }
            state.lsof.completed += 1
            state.lsof.inFlight = max(0, state.lsof.inFlight - 1)
            state.lsof.duration.record(duration)
        }
    }

    func recordLsofReuse(
        _ source: ProcessLsofReuseSource,
        token: ProcessPerformanceMetricToken
    ) {
        state.withLock { state in
            guard token.epoch == state.epoch else { return }
            switch source {
            case .cache: state.lsof.reuse.cache += 1
            case .inFlight: state.lsof.reuse.inFlight += 1
            }
        }
    }

    func recordLsofCoalescedRequest(token: ProcessPerformanceMetricToken) {
        state.withLock { state in
            guard token.epoch == state.epoch else { return }
            state.lsof.coalescedRequests += 1
        }
    }

    func recordStaleRejection(_ rejection: ProcessStaleRejection) {
        state.withLock { $0.staleRejections[rejection.rawValue, default: 0] += 1 }
    }

    func operationStarted(
        _ operation: ProcessMeasuredOperation,
        inputCount: Int
    ) -> ProcessPerformanceMetricToken {
        state.withLock { state in
            state.operations[operation.rawValue, default: ProcessPerformanceOperationMetrics()].started += 1
            state.operations[operation.rawValue, default: ProcessPerformanceOperationMetrics()].inputCount += max(0, inputCount)
            return Self.token(
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
        let duration = Self.elapsedMilliseconds(since: token.startedAtNanoseconds)
        state.withLock { state in
            guard token.epoch == state.epoch else { return }
            state.operations[token.key, default: ProcessPerformanceOperationMetrics()].completed += 1
            state.operations[token.key, default: ProcessPerformanceOperationMetrics()].outputCount += max(0, outputCount)
            state.operations[token.key, default: ProcessPerformanceOperationMetrics()].duration.record(duration)
        }
    }

    private static func token(
        key: String,
        inputCount: Int,
        epoch: UInt64
    ) -> ProcessPerformanceMetricToken {
        ProcessPerformanceMetricToken(
            key: key,
            epoch: epoch,
            startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
            inputCount: inputCount
        )
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        let end = DispatchTime.now().uptimeNanoseconds
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
#endif
