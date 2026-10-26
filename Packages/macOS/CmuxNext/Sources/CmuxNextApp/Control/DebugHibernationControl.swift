import CmuxNextCompat
import CmuxNextControl
import CmuxNextMemory
import CmuxNextSettings

/// The memory methods of the control socket:
///
/// - `debug.memory` (every build, read-only): ``DebugMemoryControl``.
/// - `debug.hibernation.pressure` (DEBUG builds): sets the memory coordinator's pressure override, which
///   the coordinator hands to browser tab hibernation (a registered `MemoryLevelConsumer`), so the fleet
///   benches (scripts/measure/tab-hibernation.sh) measure pressure without `sudo memory_pressure`.
///   `level` is normal, warning or critical and holds for both, whatever the kernel reports, until
///   `none` clears it and hands both the kernel's level again. The reply keeps `pressure`
///   (hibernation's level) and adds the coordinator's `level` and the `override`. `debug.memory`'s
///   pressure history and histograms record each override.
@MainActor
enum DebugHibernationControl {
    static func methods(_ services: AppServices) -> [ControlMethod] {
        let memory = DebugMemoryControl(services: services, budget: .forThisMac(gpuResidentAvailable: services.cache.gpuResidency != nil))
        #if DEBUG || CMUX_BENCH_HOOKS
        return [memory.method, pressureMethod(services, history: memory.history, histograms: memory.histograms)]
        #else
        return [memory.method]
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    private static func pressureMethod(_ services: AppServices, history: MemoryPressureHistory,
                                       histograms: MemoryHistograms) -> ControlMethod {
        .mainActor("debug.hibernation.pressure") { [weak services] call in
            let raw = call.params["level"]?.stringValue
            let level = raw.flatMap(MemoryPressureLevel.init(rawValue:))
            guard level != nil || raw == "none" else {
                return .value(.object(["error": .string("level must be normal, warning, critical or none")]))
            }
            guard let services else { return .value(.null) }
            let coordinator = services.memoryCoordinator
            let reply = applyOverride(level, coordinator: coordinator, hibernation: services.cache.hibernation)
            history.overrideDidChange(coordinator.pressureOverride)
            histograms.overrideDidChange(coordinator.pressureOverride)
            return .value(reply)
        }
    }

    /// Sets `coordinator`'s pressure override (nil clears it). The coordinator hands the new level to
    /// every registered `MemoryLevelConsumer` in the same turn, `hibernation` included once started.
    ///
    /// - Parameters:
    ///   - level: The level to hold, or nil for the kernel's level.
    ///   - coordinator: The app's memory coordinator.
    ///   - hibernation: The app's browser hibernation, nil before it starts.
    /// - Returns: The reply: the coordinator's `level`, the `override` and hibernation's `pressure`.
    static func applyOverride(_ level: MemoryPressureLevel?, coordinator: MemoryCoordinator,
                              hibernation: BrowserHibernation?) -> JSONValue {
        coordinator.pressureOverride = level
        var reply: [String: JSONValue] = [
            "level": .string(coordinator.level.rawValue),
            "override": level.map { .string($0.rawValue) } ?? .null,
        ]
        if let hibernation { reply["pressure"] = .string(hibernation.pressure.rawValue) }
        return .object(reply)
    }
    #endif
}
