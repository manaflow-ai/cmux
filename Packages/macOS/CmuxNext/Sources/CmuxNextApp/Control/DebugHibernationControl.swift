import CmuxNextCompat
import CmuxNextControl
import CmuxNextMemory
import CmuxNextSettings

#if DEBUG || CMUX_BENCH_HOOKS
/// `debug.hibernation.pressure` (DEBUG builds): sets the memory coordinator's pressure override and
/// hands the same level to browser tab hibernation, so the fleet benches
/// (scripts/measure/tab-hibernation.sh) measure pressure without `sudo memory_pressure`.
/// `level` is normal, warning or critical and holds for both, whatever the kernel reports, until
/// `none` clears it and hands both the kernel's level again. The reply keeps `pressure`
/// (hibernation's level) and adds the coordinator's `level` and the `override`.
@MainActor
enum DebugHibernationControl {
    static func methods(_ services: AppServices) -> [ControlMethod] {
        [
            .mainActor("debug.hibernation.pressure") { [weak services] call in
                let raw = call.params["level"]?.stringValue
                let level = raw.flatMap(MemoryPressureLevel.init(rawValue:))
                guard level != nil || raw == "none" else {
                    return .value(.object(["error": .string("level must be normal, warning, critical or none")]))
                }
                guard let services else { return .value(.null) }
                return .value(applyOverride(level, coordinator: services.memoryCoordinator, hibernation: services.cache.hibernation))
            },
            DebugDiscardsControl.method(services),
        ]
    }

    /// Sets `coordinator`'s pressure override (nil clears it) and hands its level to `hibernation` in
    /// the same turn; a hibernation that follows the coordinator keeps the override until it is cleared.
    ///
    /// - Parameters:
    ///   - level: The level to hold, or nil for the kernel's level.
    ///   - coordinator: The app's memory coordinator.
    ///   - hibernation: The app's browser hibernation, nil before it starts.
    /// - Returns: The reply: the coordinator's `level`, the `override` and hibernation's `pressure`.
    static func applyOverride(_ level: MemoryPressureLevel?, coordinator: MemoryCoordinator,
                              hibernation: BrowserHibernation?) -> JSONValue {
        coordinator.pressureOverride = level
        hibernation?.pressureDidChange(coordinator.level)
        var reply: [String: JSONValue] = [
            "level": .string(coordinator.level.rawValue),
            "override": level.map { .string($0.rawValue) } ?? .null,
        ]
        if let hibernation { reply["pressure"] = .string(hibernation.pressure.rawValue) }
        return .object(reply)
    }
}
#endif
