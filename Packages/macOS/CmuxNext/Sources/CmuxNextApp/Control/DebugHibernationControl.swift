import CmuxNextCompat
import CmuxNextControl
import CmuxNextMemory
import CmuxNextSettings

/// The memory diagnostics of the control socket:
///
/// - `debug.memory` (every build, read-only; memory-DESIGN.md section 7): pressure, mode, budget,
///   consumers, processes, tabs, workspaces, terminal surfaces, spares and the last 32 pressure
///   changes since the control socket started. The analog of Chrome's `chrome://memory-internals`.
/// - `debug.hibernation.pressure` (DEBUG builds): sets the memory coordinator's pressure override and
///   hands the same level to browser tab hibernation, so the fleet benches
///   (scripts/measure/tab-hibernation.sh) measure pressure without `sudo memory_pressure`.
///   `level` is normal, warning or critical; `none` clears the override and both go back to the
///   kernel's level. The reply keeps `pressure` (hibernation's level) and adds the coordinator's
///   `level` and the `override`. `debug.memory`'s history records each override.
@MainActor
enum DebugHibernationControl {
    static func methods(_ services: AppServices) -> [ControlMethod] {
        let history = MemoryPressureHistory(pressure: services.memoryPressure)
        let memory = memoryMethod(
            read: { [weak services] in services?.resources.memorySnapshot(history: history.changes) },
            sample: { await AppResourceSource.memoryProcesses($0) })
        #if DEBUG || CMUX_BENCH_HOOKS
        return [memory, pressureMethod(services, history: history)]
        #else
        return [memory]
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    private static func pressureMethod(_ services: AppServices, history: MemoryPressureHistory) -> ControlMethod {
        .mainActor("debug.hibernation.pressure") { [weak services] call in
            let raw = call.params["level"]?.stringValue
            let level = raw.flatMap(MemoryPressureLevel.init(rawValue:))
            guard level != nil || raw == "none" else {
                return .value(.object(["error": .string("level must be normal, warning, critical or none")]))
            }
            guard let services else { return .value(.null) }
            let coordinatorLevel = services.overrideMemoryPressure(level)
            history.record(coordinatorLevel, source: level == nil ? .kernel : .override)
            var reply: [String: JSONValue] = [
                "level": .string(coordinatorLevel.rawValue),
                "override": level.map { .string($0.rawValue) } ?? .null,
            ]
            if let hibernation = services.cache.hibernation { reply["pressure"] = .string(hibernation.pressure.rawValue) }
            return .value(.object(reply))
        }
    }
    #endif

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
