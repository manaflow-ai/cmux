import CmuxNextCompat
import CmuxNextControl

#if DEBUG || CMUX_BENCH_HOOKS
/// `debug.hibernation.pressure` (DEBUG builds): feeds a memory pressure level to browser tab
/// hibernation as the dispatch source would, so the fleet bench
/// (scripts/measure/tab-hibernation.sh) measures pressure without `sudo memory_pressure`.
/// The next real pressure event replaces it.
@MainActor
enum DebugHibernationControl {
    static func methods(_ services: AppServices) -> [ControlMethod] {
        [
            .mainActor("debug.hibernation.pressure") { [weak services] call in
                guard let raw = call.params["level"]?.stringValue, let level = MemoryPressureLevel(rawValue: raw) else {
                    return .value(.object(["error": .string("level must be normal, warning or critical")]))
                }
                guard let hibernation = services?.cache.hibernation else { return .value(.null) }
                hibernation.pressureDidChange(level)
                return .value(.object(["pressure": .string(hibernation.pressure.rawValue)]))
            },
        ]
    }
}
#endif
