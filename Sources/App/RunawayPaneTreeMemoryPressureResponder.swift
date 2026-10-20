import Darwin
import Foundation
import OSLog
import CmuxMemoryPressure

/// Stops one pane's runaway process tree before it takes the whole app down.
///
/// Terminal children share cmux's resource coalition, so a fork storm or leak
/// in one pane (https://github.com/manaflow-ai/cmux/issues/22273: ~3,500
/// `node` processes from one `next dev`) makes macOS's low-memory path act on
/// cmux itself and every session is lost. Under critical, complete aggregate
/// pressure this responder sends SIGTERM to the runaway job process groups on
/// the dominant pane's tty, then SIGKILL to the groups still on that tty after
/// a bounded grace deadline. The pane's session root and login shell are never
/// signalled. It runs after idle-agent hibernation, which is cheaper and less
/// destructive.
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
    let memoryPressurePriority = 70
    let memoryPressureResponderScope: MemoryPressureResponderScope = .all

    private let paneProvider: @MainActor () -> [PaneMemoryDescriptor]
    private let thresholdBytes: @MainActor () -> Int64
    private let snapshotProvider: SnapshotProvider
    private let aggregateProvider: AggregateProvider
    private let signalProcessGroup: ProcessGroupSignaller
    private let waitForGraceDeadline: GraceDeadline
    private let app: RunawayPaneTreeAppIdentity
    private let ttyDevice: RunawayPaneTreeSelection.TTYDeviceResolver
    private var evaluationTask: Task<Void, Never>?

    init(
        paneProvider: @escaping @MainActor () -> [PaneMemoryDescriptor],
        thresholdBytes: @escaping @MainActor () -> Int64 = { PaneMemoryGuardrail.configuredThresholdBytes() },
        snapshotProvider: @escaping SnapshotProvider = {
            // Selection is tty-scoped, so the census skips per-process
            // environment reads while memory is critical.
            await CmuxTopProcessSnapshot.capture(includeCMUXScope: false)
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
        },
        app: RunawayPaneTreeAppIdentity = .current,
        ttyDevice: @escaping RunawayPaneTreeSelection.TTYDeviceResolver = {
            CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: $0)
        }
    ) {
        self.paneProvider = paneProvider
        self.thresholdBytes = thresholdBytes
        self.snapshotProvider = snapshotProvider
        self.aggregateProvider = aggregateProvider
        self.signalProcessGroup = signalProcessGroup
        self.waitForGraceDeadline = waitForGraceDeadline
        self.app = app
        self.ttyDevice = ttyDevice
    }

    /// The in-flight evaluation, if one is running.
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
        let threshold = thresholdBytes()
        let sampledAt = snapshot.sampledAt
        let snapshotProvider = snapshotProvider
        let aggregateProvider = aggregateProvider
        let signalProcessGroup = signalProcessGroup
        let waitForGraceDeadline = waitForGraceDeadline
        let app = app
        let ttyDevice = ttyDevice
        evaluationTask = Task { @MainActor [weak self] in
            let targets = await Self.evaluate(
                descriptors: descriptors,
                thresholdBytes: threshold,
                knownAggregate: knownAggregate,
                sampledAt: sampledAt,
                snapshotProvider: snapshotProvider,
                aggregateProvider: aggregateProvider,
                signalProcessGroup: signalProcessGroup,
                waitForGraceDeadline: waitForGraceDeadline,
                app: app,
                ttyDevice: ttyDevice
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
    /// groups that are still signallable on the same tty. Returns the panes
    /// acted on.
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
        app: RunawayPaneTreeAppIdentity = .current,
        ttyDevice: RunawayPaneTreeSelection.TTYDeviceResolver = {
            CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: $0)
        }
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
            app: app,
            ttyDevice: ttyDevice
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
        for target in targets {
            let liveGroups = RunawayPaneTreeSelection.signallableProcessGroupIDs(
                ttyDevice: target.ttyDevice,
                in: freshSnapshot,
                app: app
            ) ?? []
            for processGroupID in target.processGroupIDs where liveGroups.contains(processGroupID) {
                signalProcessGroup(processGroupID, SIGKILL)
            }
        }
        return targets
    }
}
