import CmuxNextCompat
import CmuxNextControl
import CmuxNextMemory
import CmuxNextSettings

/// `debug.memory` (every build, read-only): pressure, mode, budget, consumers, processes, tabs,
/// workspaces, terminal surfaces, spares and the last 32 pressure changes since the control socket
/// started. Its keys are in schemas/debug-memory/debug-memory.schema.json. The analog of Chrome's
/// `chrome://memory-internals` (`chrome/browser/ui/webui/memory_internals/memory_internals_ui.cc`).
///
/// It owns the pressure history, so `debug.hibernation.pressure` records its overrides in the same one.
@MainActor
final class DebugMemoryControl {
    /// The pressure changes since the control socket started.
    let history: MemoryPressureHistory
    /// The memory budgets of this Mac, made once: the planned caps until each subsystem reads its own.
    let budget: SubsystemBudget
    private weak var services: AppServices?

    /// - Parameters:
    ///   - services: The app's services, held weakly.
    ///   - budget: The budgets the report shows; this Mac's by default (no GPU residency release yet).
    init(services: AppServices, budget: SubsystemBudget = .forThisMac(gpuResidentAvailable: false)) {
        self.services = services
        self.budget = budget
        history = MemoryPressureHistory(pressure: services.memoryPressure)
    }

    /// The `debug.memory` method over the app's services.
    var method: ControlMethod {
        Self.memoryMethod(read: { [self] in snapshot() }, sample: { await AppMemoryModel.processes($0) })
    }

    /// The app's memory state now; nil once the app's services are gone.
    func snapshot() -> MemoryDiagnosticsSnapshot? {
        guard let services else { return nil }
        return AppMemoryModel(services: services, budget: budget).memorySnapshot(history: history.snapshot)
    }

    /// `debug.memory`: `read` copies the model in one main-actor work item (the control queue's
    /// automation class, after the person's input), then `sample` reads the process footprints and
    /// the report is encoded off the main actor. It changes nothing and its answer has no URL,
    /// title or path (``MemoryDiagnosticsReport``), so release builds serve it too.
    ///
    /// - Parameters:
    ///   - read: The app's memory state; nil once the app's services are gone.
    ///   - sample: Reads the footprints of the snapshot's processes, off the main actor.
    static func memoryMethod(
        read: @escaping @MainActor @Sendable () -> MemoryDiagnosticsSnapshot?,
        sample: @escaping @concurrent @Sendable (MemoryDiagnosticsSnapshot) async -> MemoryDiagnosticsProcesses
    ) -> ControlMethod {
        ControlMethod.mainActor("debug.memory") { _ in
            guard let snapshot = read() else { return .value(.null) }
            return .followUp {
                let report = MemoryDiagnosticsReport(snapshot: snapshot, processes: await sample(snapshot))
                return try JSONValue.parse(report.jsonData())
            }
        }.servingRelease()
    }
}
