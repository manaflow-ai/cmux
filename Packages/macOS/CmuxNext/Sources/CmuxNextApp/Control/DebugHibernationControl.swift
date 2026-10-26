import CmuxNextCompat
import CmuxNextControl
import CmuxNextSettings

#if DEBUG || CMUX_BENCH_HOOKS
/// `debug.hibernation.pressure` (DEBUG builds): sets the memory coordinator's pressure override and
/// hands the same level to browser tab hibernation, so the fleet benches
/// (scripts/measure/tab-hibernation.sh) measure pressure without `sudo memory_pressure`.
/// `level` is normal, warning or critical; `none` clears the override and both go back to the
/// kernel's level. The reply keeps `pressure` (hibernation's level) and adds the coordinator's
/// `level` and the `override`.
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
                let coordinatorLevel = services.overrideMemoryPressure(level)
                var reply: [String: JSONValue] = [
                    "level": .string(coordinatorLevel.rawValue),
                    "override": level.map { .string($0.rawValue) } ?? .null,
                ]
                if let hibernation = services.cache.hibernation { reply["pressure"] = .string(hibernation.pressure.rawValue) }
                return .value(.object(reply))
            },
        ]
    }
}
#endif
