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

    @ObservationIgnored
    var onPersistentCriticalPressure: (@MainActor (MemoryPressureSnapshot) -> Void)?

    @ObservationIgnored
    private let footprintSampler: any MemoryPressureFootprintSampling
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

    init(
        registry: MemoryPressureResponderRegistry? = nil,
        footprintSampler: any MemoryPressureFootprintSampling = TaskVMInfoMemoryPressureFootprintSampler(),
        thresholds: MemoryPressureFootprintThresholds = .default,
        criticalPersistenceDuration: TimeInterval = 60,
        sampleInterval: TimeInterval = 30,
        systemPressureHoldDuration: TimeInterval = 120
    ) {
        self.registry = registry ?? MemoryPressureResponderRegistry()
        self.footprintSampler = footprintSampler
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
        samplePhysicalFootprint(at: Date())
    }

    func samplePhysicalFootprint(at sampledAt: Date = Date()) {
        apply(
            systemSeverity: heldSystemSeverity(at: sampledAt),
            physicalFootprintBytes: footprintSampler.physicalFootprintBytes(),
            sampledAt: sampledAt
        )
    }

    func recordSystemPressure(_ severity: MemoryPressureSeverity, at sampledAt: Date = Date()) {
        let heldSeverity = heldSystemSeverity(at: sampledAt) ?? .normal
        let effectiveSeverity = max(severity, heldSeverity)
        activeSystemSeverity = effectiveSeverity
        activeSystemSeverityExpiresAt = sampledAt.addingTimeInterval(systemPressureHoldDuration)
        apply(
            systemSeverity: effectiveSeverity,
            physicalFootprintBytes: footprintSampler.physicalFootprintBytes(),
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
            let sampledAt = Date()
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
        timer.setEventHandler { [weak self] in
            let sampledAt = Date()
            Task { @MainActor in
                self?.samplePhysicalFootprint(at: sampledAt)
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
        sampledAt: Date
    ) {
        let evaluation = stateTracker.ingest(
            systemSeverity: systemSeverity,
            physicalFootprintBytes: physicalFootprintBytes,
            sampledAt: sampledAt
        )
        currentSeverity = evaluation.snapshot.severity
        self.physicalFootprintBytes = evaluation.snapshot.physicalFootprintBytes

        if evaluation.didTransition {
            logTransition(evaluation)
        }
        if evaluation.snapshot.severity >= .warning {
            registry.dispatch(evaluation.snapshot)
        }
        if evaluation.didBecomePersistentCritical {
            onPersistentCriticalPressure?(evaluation.snapshot)
        }
    }

    private func logTransition(_ evaluation: MemoryPressureStateEvaluation) {
        let snapshot = evaluation.snapshot
        let footprint = Self.byteDescription(snapshot.physicalFootprintBytes)
        Self.logger.info(
            "memoryPressure.transition previous=\(evaluation.previousSeverity.logName, privacy: .public) severity=\(snapshot.severity.logName, privacy: .public) footprint=\(footprint, privacy: .public)"
        )
        let signpostID = Self.signposter.makeSignpostID()
        Self.signposter.emitEvent(
            "MemoryPressureTransition",
            id: signpostID,
            "previous=\(evaluation.previousSeverity.logName) severity=\(snapshot.severity.logName) footprint=\(footprint)"
        )
    }

    private static func byteDescription(_ bytes: UInt64?) -> String {
        bytes.map(String.init) ?? "unknown"
    }
}
