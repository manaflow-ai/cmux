import Darwin
import Foundation
import OSLog
import CmuxMemoryPressure

/// Stops one pane's runaway process tree before it takes the whole app down.
///
/// Terminal children share cmux's resource coalition, so a fork storm or leak
/// in one pane (issue #22273: ~3,500 `node` processes from one `next dev`)
/// makes macOS's low-memory path act on cmux itself and every session is
/// lost. Under critical, complete aggregate pressure this responder sends
/// SIGTERM to the dominant pane's runaway job process groups, then SIGKILL to
/// the groups still alive in that pane after a bounded grace deadline. The
/// pane's login and shell groups are never signalled.
@MainActor
final class RunawayPaneTreeMemoryPressureResponder: MemoryPressureResponder {
    typealias SnapshotProvider = @Sendable () async -> CmuxTopProcessSnapshot
    typealias AggregateProvider = @Sendable (Date) async -> MemoryPressureAggregateSnapshot
    typealias ProcessGroupSignaller = @Sendable (_ processGroupID: Int, _ signal: Int32) -> Void
    typealias GraceDeadline = @Sendable () async -> Bool

    private static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "MemoryPressure"
    )

    let memoryPressureResponderID = "runaway-pane-tree"
    let memoryPressureMinimumSeverity: MemoryPressureSeverity = .critical
    let memoryPressurePriority = 90
    let memoryPressureResponderScope: MemoryPressureResponderScope = .all

    private let paneProvider: @MainActor () -> [PaneMemoryDescriptor]
    private let thresholdBytes: @MainActor () -> Int64
    private let snapshotProvider: SnapshotProvider
    private let aggregateProvider: AggregateProvider
    private let signalProcessGroup: ProcessGroupSignaller
    private let waitForGraceDeadline: GraceDeadline
    private var evaluationTask: Task<Void, Never>?

    init(
        paneProvider: @escaping @MainActor () -> [PaneMemoryDescriptor],
        thresholdBytes: @escaping @MainActor () -> Int64 = { PaneMemoryGuardrail.configuredThresholdBytes() },
        snapshotProvider: @escaping SnapshotProvider = {
            await CmuxTopProcessSnapshot.capture(includeCMUXScope: true)
        },
        aggregateProvider: @escaping AggregateProvider = { sampledAt in
            let sampler = DarwinMemoryPressureAggregateSampler(
                snapshotProvider: {
                    await CmuxTopProcessSnapshot.capture(includeCMUXScope: false)
                }
            )
            let sample = await sampler.sample(at: sampledAt)
            return MemoryPressureAggregatePolicy.default.evaluate(sample: sample)
        },
        signalProcessGroup: @escaping ProcessGroupSignaller = { processGroupID, signal in
            _ = kill(pid_t(-processGroupID), signal)
        },
        waitForGraceDeadline: @escaping GraceDeadline = {
            do {
                // Genuine SIGTERM grace deadline; cancellation skips escalation.
                try await ContinuousClock().sleep(for: .seconds(3))
                return true
            } catch {
                return false
            }
        }
    ) {
        self.paneProvider = paneProvider
        self.thresholdBytes = thresholdBytes
        self.snapshotProvider = snapshotProvider
        self.aggregateProvider = aggregateProvider
        self.signalProcessGroup = signalProcessGroup
        self.waitForGraceDeadline = waitForGraceDeadline
    }

    /// The in-flight evaluation, exposed so tests can await completion.
    var pendingEvaluation: Task<Void, Never>? { evaluationTask }

    func shedMemory(for snapshot: MemoryPressureSnapshot) -> MemoryPressureShedResult {
        guard evaluationTask == nil else {
            return MemoryPressureShedResult(reclaimedItemCount: 0, detail: "runaway-pane-evaluation-in-flight")
        }
        let knownAggregate = snapshot.aggregateMemoryPressure
        if let knownAggregate, !Self.authorizesTermination(knownAggregate) {
            return MemoryPressureShedResult(reclaimedItemCount: 0, detail: "aggregate-not-critical")
        }
        let descriptors = paneProvider()
        guard !descriptors.isEmpty else {
            return MemoryPressureShedResult(reclaimedItemCount: 0, detail: "no-terminal-panes")
        }

        let responderID = memoryPressureResponderID
        let severity = snapshot.severity
        let thresholdBytes = thresholdBytes()
        let sampledAt = snapshot.sampledAt
        let snapshotProvider = snapshotProvider
        let aggregateProvider = aggregateProvider
        let signalProcessGroup = signalProcessGroup
        let waitForGraceDeadline = waitForGraceDeadline
        evaluationTask = Task { @MainActor [weak self] in
            let targets = await Self.evaluate(
                descriptors: descriptors,
                thresholdBytes: thresholdBytes,
                knownAggregate: knownAggregate,
                sampledAt: sampledAt,
                snapshotProvider: snapshotProvider,
                aggregateProvider: aggregateProvider,
                signalProcessGroup: signalProcessGroup,
                waitForGraceDeadline: waitForGraceDeadline
            )
            self?.evaluationTask = nil
            guard !targets.isEmpty else { return }
            let bytes = targets.reduce(Int64(0)) { CmuxTopProcessSnapshot.clampedAdd($0, $1.memoryBytes) }
            let processCount = targets.reduce(0) { $0 + $1.processCount }
            Self.logger.notice(
                "memoryPressure.runawayPaneTree panes=\(targets.count, privacy: .public) processGroups=\(targets.flatMap(\.processGroupIDs).count, privacy: .public) processes=\(processCount, privacy: .public) bytes=\(bytes, privacy: .public)"
            )
            MemoryPressureResponderRegistry.logShedAction(
                MemoryPressureShedAction(
                    responderID: responderID,
                    severity: severity,
                    reclaimedItemCount: targets.count,
                    estimatedBytes: UInt64(max(0, bytes)),
                    detail: "runaway-pane-tree",
                    performedAt: .now
                )
            )
        }
        return MemoryPressureShedResult(reclaimedItemCount: 0, detail: "runaway-pane-evaluation")
    }

    /// Only critical pressure from a complete measurement may stop a process.
    nonisolated static func authorizesTermination(_ aggregate: MemoryPressureAggregateSnapshot) -> Bool {
        aggregate.isActionable && aggregate.severity == .critical
    }

    /// Re-checks aggregate pressure, selects runaway panes from a fresh census,
    /// sends SIGTERM, and after the grace deadline sends SIGKILL to the selected
    /// groups that still belong to the same pane. Returns the panes acted on.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated static func evaluate(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64,
        knownAggregate: MemoryPressureAggregateSnapshot?,
        sampledAt: Date,
        snapshotProvider: SnapshotProvider,
        aggregateProvider: AggregateProvider,
        signalProcessGroup: ProcessGroupSignaller,
        waitForGraceDeadline: GraceDeadline,
        currentProcessGroupID: Int = Int(getpgrp())
    ) async -> [RunawayPaneTreeTarget] {
        let aggregate: MemoryPressureAggregateSnapshot
        if let knownAggregate {
            aggregate = knownAggregate
        } else {
            aggregate = await aggregateProvider(sampledAt)
        }
        guard authorizesTermination(aggregate),
              let aggregateBytes = aggregate.aggregateBytes else { return [] }

        let snapshot = await snapshotProvider()
        let targets = RunawayPaneTreeSelection.targets(
            descriptors: descriptors,
            snapshot: snapshot,
            aggregateBytes: aggregateBytes,
            thresholdBytes: thresholdBytes,
            currentProcessGroupID: currentProcessGroupID
        )
        guard !targets.isEmpty else { return [] }
        for target in targets {
            for processGroupID in target.processGroupIDs {
                signalProcessGroup(processGroupID, SIGTERM)
            }
        }

        guard await waitForGraceDeadline() else { return targets }
        let freshSnapshot = await snapshotProvider()
        guard freshSnapshot.captureIsAvailable, freshSnapshot.enumerationIsComplete else {
            // Without a complete census a reused group ID cannot be ruled out.
            return targets
        }
        let descriptorsByKey = Dictionary(
            descriptors.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for target in targets {
            guard let descriptor = descriptorsByKey[target.key] else { continue }
            let pids = RunawayPaneTreeSelection.panePIDs(for: descriptor, in: freshSnapshot)
            let liveGroups = Set(pids.compactMap { freshSnapshot.process(pid: $0)?.processGroupID })
            let protectedGroups = RunawayPaneTreeSelection
                .protectedProcessGroupIDs(pids: pids, in: freshSnapshot)
                .union([currentProcessGroupID])
            for processGroupID in target.processGroupIDs
            where liveGroups.contains(processGroupID) && !protectedGroups.contains(processGroupID) {
                signalProcessGroup(processGroupID, SIGKILL)
            }
        }
        return targets
    }
}
