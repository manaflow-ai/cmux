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
/// `spares` lists every spare by pool, each with its process and bytes: the page spares, Chromium's spare
/// windows (their placeholder's renderer) and, as `chromium_unattributed_renderer`, each sampled renderer
/// helper that hosts no frame of any browser (``MemoryDiagnosticsProcesses/rendererClientsWithFrames``).
/// Chromium's own spare is one of those, but so is a renderer whose page has not committed yet: the fork
/// has no read of the spare's id, which Chrome's Task Manager matches its "Spare Renderer" row on, so the
/// row does not claim to be the spare. With `chromiumOneSpareRenderer`, Home keeps at most one.
///
/// It owns the pressure history, so `debug.hibernation.pressure` records its overrides in the same one.
/// A read records nothing: the histograms' footprints come from ``MemoryFootprintEmitter``, as a
/// `chrome://memory-internals` read adds no sample to Chrome's memory histograms.
///
/// Socket policy of the memory diagnostics (`debug.memory`, ``DebugHibernationControl``'s
/// `debug.discards`):
/// - Lane: one short main-actor copy in the automation class, after the person's input; parsing,
///   sampling and encoding run off the main actor. Not an input method (``ControlMethod/injectingInput()``).
/// - Focus: none. It changes nothing: no selection, window, activation or pressure change.
/// - Who: the control socket admits only the local owner (same uid, ``ControlAccessMode``); no relay
///   forwards it (`RemoteRelayPolicy` never allowlists a `debug`, `memory` or `discards` method), and
///   the daemon's `memory-report` refuses every client off its trusted local socket.
/// - Release: IDs and names go through ``MemoryDiagnosticsReport/opaqueToken(_:)``, so the answer has
///   no URL, title or path, as Chrome's background memory dumps keep only allowlisted names
///   (`base/trace_event/memory_infra_background_allowlist.cc`).
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
    ///   - budget: The budgets the report shows: the app passes this Mac's, sized for the terminal GPU release when it has one.
    ///   - sample: Reads the footprints; nil: the app's processes and the Chromium helpers of its helper parent, with
    ///     the renderers that host a frame.
    init(services: AppServices, budget: SubsystemBudget = .forThisMac(gpuResidentAvailable: false), sample: Sampler? = nil) {
        self.services = services
        self.budget = budget
        let parent = services.cache.chromium.source.helperParent
        let framed: @MainActor @Sendable () -> Set<Int32>? = { [weak services] in AppMemoryModel.rendererClientsWithFrames(services) }
        let appSample: Sampler = { await AppMemoryModel.processes($0, helperParent: parent.pid, rendererClientsWithFrames: framed) }
        self.sample = sample ?? appSample
        history = MemoryPressureHistory(pressure: services.memoryPressure)
        histograms = services.memoryHistograms
    }

    /// The `debug.memory` method over the app's services.
    var method: ControlMethod {
        Self.memoryMethod(read: { [self] in snapshot() }, sample: sample)
    }

    /// The app's memory state now, with a copy of the histograms; nil once the app's services are gone.
    func snapshot() -> MemoryDiagnosticsSnapshot? {
        guard let services else { return nil }
        var snapshot = AppMemoryModel(services: services, budget: budget).memorySnapshot(history: history.snapshot)
        snapshot.histograms = histograms.snapshot()
        return snapshot
    }

    /// `debug.memory`: `read` copies the model and the histograms in one main-actor work item (the
    /// control queue's automation class, after the person's input), then `sample` reads the process
    /// footprints and the report is encoded off the main actor. It changes nothing and its answer has
    /// no URL, title or path (``MemoryDiagnosticsReport``), so release builds serve it too.
    ///
    /// - Parameters:
    ///   - read: The app's memory state; nil once the app's services are gone.
    ///   - sample: Reads the footprints of the snapshot's processes, off the main actor.
    static func memoryMethod(
        read: @escaping @MainActor @Sendable () -> MemoryDiagnosticsSnapshot?,
        sample: @escaping Sampler
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
