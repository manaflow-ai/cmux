import CmuxNextCompat
import CmuxNextControl
import CmuxNextMemory
import CmuxNextSettings

/// `debug.memory` (every build, read-only): pressure, mode, budget, consumers, processes, tabs,
/// workspaces, terminal surfaces, spares, the last 32 pressure changes since the control socket
/// started and the local memory histograms (``MemoryHistograms``, never uploaded). Its keys are in
/// schemas/debug-memory/debug-memory.schema.json. The analog of Chrome's `chrome://memory-internals`
/// (`chrome/browser/ui/webui/memory_internals/memory_internals_ui.cc`).
///
/// It owns the pressure history, so `debug.hibernation.pressure` records its overrides in the same one,
/// and it samples the footprints into the histograms at each applied level change and each read, as
/// Chrome's `ProcessMemoryMetricsEmitter` (`chrome/browser/metrics/process_memory_metrics_emitter.cc`)
/// samples on its owner's events, with no timer.
@MainActor
final class DebugMemoryControl {
    /// Reads the footprints of a snapshot's processes, off the main actor.
    typealias Sampler = @concurrent @Sendable (MemoryDiagnosticsSnapshot) async -> MemoryDiagnosticsProcesses

    /// The pressure changes since the control socket started.
    let history: MemoryPressureHistory
    /// The app's local memory histograms.
    let histograms: MemoryHistograms
    /// The memory budgets of this Mac, made once: the planned caps until each subsystem reads its own.
    let budget: SubsystemBudget
    private weak var services: AppServices?
    private let sample: Sampler

    /// - Parameters:
    ///   - services: The app's services, held weakly.
    ///   - budget: The budgets the report shows; this Mac's by default (no GPU residency release yet).
    ///   - sample: Reads the footprints; the app's processes by default.
    init(services: AppServices, budget: SubsystemBudget = .forThisMac(gpuResidentAvailable: false),
         sample: @escaping Sampler = { await AppMemoryModel.processes($0) }) {
        self.services = services
        self.budget = budget
        self.sample = sample
        history = MemoryPressureHistory(pressure: services.memoryPressure)
        histograms = services.memoryHistograms
        histograms.sampleFootprints = { [weak self] in
            guard let snapshot = self?.snapshot() else { return nil }
            return await sample(snapshot)
        }
    }

    /// The `debug.memory` method over the app's services.
    var method: ControlMethod {
        Self.memoryMethod(read: { [self] in snapshot() }, sample: sample, record: { [self] processes in
            histograms.recordFootprints(processes)
            return histograms.snapshot()
        })
    }

    /// The app's memory state now; nil once the app's services are gone.
    func snapshot() -> MemoryDiagnosticsSnapshot? {
        guard let services else { return nil }
        var snapshot = AppMemoryModel(services: services, budget: budget).memorySnapshot(history: history.snapshot)
        snapshot.histograms = histograms.snapshot()
        return snapshot
    }

    /// `debug.memory`: `read` copies the model in one main-actor work item (the control queue's
    /// automation class, after the person's input), then `sample` reads the process footprints off
    /// the main actor, `record` adds them to the histograms back on it, and the report is encoded off
    /// it. It changes nothing but the local histograms, and its answer has no URL, title or path
    /// (``MemoryDiagnosticsReport``), so release builds serve it too.
    ///
    /// - Parameters:
    ///   - read: The app's memory state; nil once the app's services are gone.
    ///   - sample: Reads the footprints of the snapshot's processes, off the main actor.
    ///   - record: Records the footprints in the histograms and returns them; nil keeps the read's histograms.
    static func memoryMethod(
        read: @escaping @MainActor @Sendable () -> MemoryDiagnosticsSnapshot?,
        sample: @escaping Sampler,
        record: @escaping @MainActor @Sendable (MemoryDiagnosticsProcesses) -> MemoryHistograms.Snapshot? = { _ in nil }
    ) -> ControlMethod {
        ControlMethod.mainActor("debug.memory") { _ in
            guard let snapshot = read() else { return .value(.null) }
            return .followUp {
                let processes = await sample(snapshot)
                var recorded = snapshot
                if let histograms = await record(processes) { recorded.histograms = histograms }
                let report = MemoryDiagnosticsReport(snapshot: recorded, processes: processes)
                return try JSONValue.parse(report.jsonData())
            }
        }.servingRelease()
    }
}
