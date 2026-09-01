import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()

    private static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "MemoryPressure"
    )
    private static let signposter = OSSignposter(
        subsystem: "com.cmuxterm.app",
        category: "MemoryPressure"
    )

    let registry: MemoryPressureResponderRegistry
    private(set) var currentSeverity: MemoryPressureSeverity = .normal
    private(set) var physicalFootprintBytes: UInt64?
    private(set) var aggregateMemoryPressure: MemoryPressureAggregateSnapshot?

    @ObservationIgnored
    var onPersistentCriticalPressure: (@MainActor (MemoryPressureSnapshot) -> Void)?

    @ObservationIgnored
    var onAggregatePressureCleared: (@MainActor () -> Void)?

    @ObservationIgnored
    private let footprintSampler: any MemoryPressureFootprintSampling
    @ObservationIgnored
    private let aggregateSampler: any MemoryPressureAggregateSampling
    @ObservationIgnored
    private let aggregatePolicy: MemoryPressureAggregatePolicy
    @ObservationIgnored
    private var stateTracker: MemoryPressureStateTracker
    @ObservationIgnored
    private let sampleInterval: TimeInterval
    @ObservationIgnored
    private let systemPressureHoldDuration: TimeInterval
    @ObservationIgnored
    private let queue = DispatchQueue(label: "com.cmux.memory-pressure", qos: .utility)
    @ObservationIgnored
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored
    private var sampleTimer: DispatchSourceTimer?
    @ObservationIgnored
    private var activeSystemSeverity: MemoryPressureSeverity = .normal
    @ObservationIgnored
    private var activeSystemSeverityExpiresAt: Date?
    @ObservationIgnored
    private var lastAggregateSample: MemoryPressureAggregateSample?
    @ObservationIgnored
    private var lastAppliedSampledAt = Date.distantPast

    init(
        registry: MemoryPressureResponderRegistry? = nil,
        footprintSampler: any MemoryPressureFootprintSampling = TaskVMInfoMemoryPressureFootprintSampler(),
        aggregateSampler: any MemoryPressureAggregateSampling = DarwinMemoryPressureAggregateSampler(),
        aggregatePolicy: MemoryPressureAggregatePolicy = .default,
        thresholds: MemoryPressureFootprintThresholds = .default,
        criticalPersistenceDuration: TimeInterval = 60,
        sampleInterval: TimeInterval = 30,
        systemPressureHoldDuration: TimeInterval = 120
    ) {
        self.registry = registry ?? MemoryPressureResponderRegistry()
        self.footprintSampler = footprintSampler
        self.aggregateSampler = aggregateSampler
        self.aggregatePolicy = aggregatePolicy
        stateTracker = MemoryPressureStateTracker(
            thresholds: thresholds,
            criticalPersistenceDuration: criticalPersistenceDuration
        )
        self.sampleInterval = sampleInterval
        self.systemPressureHoldDuration = Swift.max(0, systemPressureHoldDuration)
    }

    func start() {
        startMemoryPressureSourceIfNeeded()
        startSampleTimerIfNeeded()
        Task { @MainActor [weak self] in
            await self?.samplePhysicalFootprint(at: .now)
        }
    }

    func samplePhysicalFootprint(at sampledAt: Date = .now) async {
        let footprintBytes = footprintSampler.physicalFootprintBytes()
        let aggregateSample = await Self.captureAggregateSample(
            using: aggregateSampler,
            at: sampledAt
        )
        lastAggregateSample = aggregateSample
        apply(
            systemSeverity: heldSystemSeverity(at: sampledAt),
            physicalFootprintBytes: footprintBytes,
            aggregateSample: aggregateSample,
            sampledAt: sampledAt
        )
    }

    func recordSystemPressure(_ severity: MemoryPressureSeverity, at sampledAt: Date = .now) {
        guard sampledAt >= lastAppliedSampledAt else { return }
        let heldSeverity = heldSystemSeverity(at: sampledAt) ?? .normal
        let effectiveSeverity = max(severity, heldSeverity)
        activeSystemSeverity = effectiveSeverity
        activeSystemSeverityExpiresAt = sampledAt.addingTimeInterval(systemPressureHoldDuration)
        // Do not replay an old aggregate sample from an unrelated system event.
        // The next periodic sample will publish fresh aggregate evidence; until
        // then an in-flight aggregate hibernation pass must be allowed to stop.
        lastAggregateSample = nil
        apply(
            systemSeverity: effectiveSeverity,
            physicalFootprintBytes: footprintSampler.physicalFootprintBytes(),
            aggregateSample: nil,
            sampledAt: sampledAt
        )
    }

    nonisolated static func severity(
        forDispatchSourceEvent event: DispatchSource.MemoryPressureEvent
    ) -> MemoryPressureSeverity? {
        if event.contains(.critical) {
            return .critical
        }
        if event.contains(.warning) {
            return .warning
        }
        return nil
    }

#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated private static func captureAggregateSample(
        using sampler: any MemoryPressureAggregateSampling,
        at sampledAt: Date
    ) async -> MemoryPressureAggregateSample {
        sampler.sample(at: sampledAt)
    }

    private func startMemoryPressureSourceIfNeeded() {
        guard memoryPressureSource == nil else { return }
        // DispatchSource memory-pressure notifications are the system signal
        // emitted before the kernel's low-swap kill path. There is no async
        // native replacement for this signal.
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data,
                  let severity = Self.severity(forDispatchSourceEvent: event) else {
                return
            }
            let sampledAt = Date.now
            Task { @MainActor in
                self?.recordSystemPressure(severity, at: sampledAt)
            }
        }
        memoryPressureSource = source
        source.resume()
    }

    private func startSampleTimerIfNeeded() {
        guard sampleTimer == nil else { return }
        // task_vm_info has no push/async notification API for phys_footprint, so
        // periodic sampling is required to detect footprint growth between
        // system memory-pressure events.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + sampleInterval,
            repeating: sampleInterval,
            leeway: .seconds(5)
        )
        let footprintSampler = self.footprintSampler
        let aggregateSampler = self.aggregateSampler
        timer.setEventHandler { [weak self] in
            let sampledAt = Date()
            let footprintBytes = footprintSampler.physicalFootprintBytes()
            let aggregateSample = aggregateSampler.sample(at: sampledAt)
            Task { @MainActor in
                guard let self else { return }
                self.lastAggregateSample = aggregateSample
                self.apply(
                    systemSeverity: self.heldSystemSeverity(at: sampledAt),
                    physicalFootprintBytes: footprintBytes,
                    aggregateSample: aggregateSample,
                    sampledAt: sampledAt
                )
            }
        }
        sampleTimer = timer
        timer.resume()
    }

    private func heldSystemSeverity(at sampledAt: Date) -> MemoryPressureSeverity? {
        guard activeSystemSeverity >= .warning,
              let activeSystemSeverityExpiresAt,
              sampledAt <= activeSystemSeverityExpiresAt else {
            activeSystemSeverity = .normal
            activeSystemSeverityExpiresAt = nil
            return nil
        }
        return activeSystemSeverity
    }

    private func apply(
        systemSeverity: MemoryPressureSeverity?,
        physicalFootprintBytes: UInt64?,
        aggregateSample: MemoryPressureAggregateSample?,
        sampledAt: Date
    ) {
        guard sampledAt >= lastAppliedSampledAt else {
            // Initial sampling is asynchronous; discard an older result that
            // arrived after a newer timer or pressure-event sample.
            return
        }
        lastAppliedSampledAt = sampledAt
        // Keep aggregate severity intrinsic to cmux's coalition/tree. The
        // independent Dispatch/system signal still drives the overall tracker,
        // but must not turn a low aggregate sample into a hibernation command.
        let aggregateMemoryPressure = aggregateSample.map {
            aggregatePolicy.evaluate(
                sample: $0
            )
        }
        let evaluation = stateTracker.ingest(
            systemSeverity: systemSeverity,
            physicalFootprintBytes: physicalFootprintBytes,
            aggregateMemoryPressure: aggregateMemoryPressure,
            sampledAt: sampledAt
        )
        currentSeverity = evaluation.snapshot.severity
        self.physicalFootprintBytes = evaluation.snapshot.physicalFootprintBytes
        self.aggregateMemoryPressure = aggregateMemoryPressure
        if aggregateMemoryPressure?.isActionable != true {
            onAggregatePressureCleared?()
        }

        if evaluation.didTransition {
            logTransition(evaluation)
        }
        if evaluation.snapshot.severity >= .warning {
            registry.dispatch(evaluation.snapshot, signal: .system)
        }
        if let aggregateMemoryPressure,
           aggregateMemoryPressure.isActionable {
            // Aggregate pressure gets its own dispatch lane. This preserves
            // the visible warning + idle-agent hibernation contract without
            // making aggregate thresholds release unrelated hidden resources.
            let aggregateSnapshot = MemoryPressureSnapshot(
                severity: aggregateMemoryPressure.severity,
                physicalFootprintBytes: physicalFootprintBytes,
                aggregateMemoryPressure: aggregateMemoryPressure,
                sampledAt: sampledAt
            )
            registry.dispatch(aggregateSnapshot, signal: .aggregate)
        }
        if evaluation.didBecomePersistentCritical {
            onPersistentCriticalPressure?(evaluation.snapshot)
        }
    }

    private func logTransition(_ evaluation: MemoryPressureStateEvaluation) {
        let snapshot = evaluation.snapshot
        let footprint = Self.byteDescription(snapshot.physicalFootprintBytes)
        let aggregate = snapshot.aggregateMemoryPressure
        let aggregateBytes = Self.byteDescription(aggregate?.aggregateBytes)
        let aggregateSource = aggregate?.source.rawValue ?? "unavailable"
        Self.logger.info(
            "memoryPressure.transition previous=\(evaluation.previousSeverity.logName, privacy: .public) severity=\(snapshot.severity.logName, privacy: .public) footprint=\(footprint, privacy: .public) aggregateSource=\(aggregateSource, privacy: .public) aggregateBytes=\(aggregateBytes, privacy: .public)"
        )
        let signpostID = Self.signposter.makeSignpostID()
        Self.signposter.emitEvent(
            "MemoryPressureTransition",
            id: signpostID,
            "previous=\(evaluation.previousSeverity.logName) severity=\(snapshot.severity.logName) footprint=\(footprint) aggregateSource=\(aggregateSource) aggregateBytes=\(aggregateBytes)"
        )
    }

    private static func byteDescription(_ bytes: UInt64?) -> String {
        bytes.map(String.init) ?? "unknown"
    }
}
