import CmuxFoundation
import CmuxTerminal
import Darwin
import Foundation

/// One resource sample shared by local diagnostics and opt-in Sentry reporting.
struct MemoryResourceSample: Sendable {
    private let appPID: Int
    private let appProcess: CmuxTopProcessInfo?
    private let sampledAt: Date
    private let surfaces: TerminalSurfaceRegistryDiagnosticSnapshot
    private let system: DarwinSystemMemorySnapshot?
    private let aggregate: MemoryPressureAggregateSample
    private let descendants: MemoryResourceDiagnostics
    private let descriptors: DarwinFileDescriptorSnapshot

    /// Called on the sampling worker; UI-owned counts are supplied separately.
    init(processSnapshot: CmuxTopProcessSnapshot, appPID: Int = Int(getpid())) {
        self.appPID = appPID
        appProcess = processSnapshot.process(pid: appPID)
        sampledAt = processSnapshot.sampledAt
        surfaces = GhosttyApp.terminalSurfaceRegistry.diagnosticSnapshot()
        let system = DarwinSystemMemorySnapshot()
        self.system = system
        aggregate = DarwinMemoryPressureAggregateSampler(
            processID: appPID,
            snapshotProvider: { processSnapshot },
            availableMemoryProvider: { system?.availableBytes }
        ).sample(at: processSnapshot.sampledAt)
        descendants = MemoryResourceDiagnostics(snapshot: processSnapshot, appPID: appPID)
        descriptors = DarwinFileDescriptorSnapshot(processID: pid_t(appPID))
    }

    func payload(views: MemoryResourceViewCounts, monitor: [String: Any]) -> [String: Any] {
        var aggregatePayload = aggregate.privacySafeDiagnosticPayload()
        aggregatePayload["severity"] = MemoryPressureAggregatePolicy.default
            .severity(for: aggregate).logName
        let memorySource = appProcess?.memorySource.rawValue ?? CmuxTopProcessMemorySource.unavailable.rawValue
        let residentSource = appProcess?.residentMemorySource.rawValue ?? CmuxTopProcessMemorySource.unavailable.rawValue
        return [
            "sampled_at": ISO8601DateFormatter().string(from: sampledAt),
            "app": [
                "pid": appPID,
                "physical_footprint_bytes": appProcess?.memoryBytes ?? 0,
                "resident_bytes": appProcess?.residentBytes ?? 0,
                "virtual_bytes": appProcess?.virtualBytes ?? 0,
                "thread_count": appProcess?.threadCount ?? 0,
                "memory_source": memorySource,
                "resident_memory_source": residentSource
            ],
            "terminal_surfaces": surfaces.payload(),
            "aggregate": aggregatePayload,
            "descendants": descendants.payload(),
            "system_memory": system?.payload() as Any? ?? NSNull(),
            "file_descriptors": descriptors.payload(),
            "views": views.payload(),
            "monitor": monitor
        ]
    }
}
