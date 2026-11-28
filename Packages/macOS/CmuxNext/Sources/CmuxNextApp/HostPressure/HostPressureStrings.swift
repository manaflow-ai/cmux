import Foundation

/// The host pressure indicator's and popover's text (`HostPressure.xcstrings`). acpmux's
/// reasons (`over`) are shown in its own words.
enum HostPressureStrings {
    static var warningTitle: String {
        String(localized: "hostPressure.title.warning", defaultValue: "This Mac is busy", table: "HostPressure", bundle: .module.inAppLanguage)
    }

    static var criticalTitle: String {
        String(localized: "hostPressure.title.critical", defaultValue: "This Mac is overloaded", table: "HostPressure", bundle: .module.inAppLanguage)
    }

    static var warnOnly: String {
        String(localized: "hostPressure.warnOnly", defaultValue: "cmux only warns. Nothing is paused or stopped.",
               table: "HostPressure", bundle: .module.inAppLanguage)
    }

    /// The 1-minute load and the budget's limit, both already formatted.
    static func load(_ load: String, limit: String) -> String {
        String(format: String(localized: "hostPressure.load", defaultValue: "Load %1$@, limit %2$@", table: "HostPressure", bundle: .module.inAppLanguage),
               load, limit)
    }

    static var turns: String {
        String(localized: "hostPressure.turns", defaultValue: "Turns", table: "HostPressure", bundle: .module.inAppLanguage)
    }

    static var processes: String {
        String(localized: "hostPressure.processes", defaultValue: "Processes", table: "HostPressure", bundle: .module.inAppLanguage)
    }

    static var sessions: String {
        String(localized: "hostPressure.sessions", defaultValue: "Busiest sessions", table: "HostPressure", bundle: .module.inAppLanguage)
    }

    static var stop: String {
        String(localized: "hostPressure.stop", defaultValue: "Stop", table: "HostPressure", bundle: .module.inAppLanguage)
    }

    /// The critical banner: the title's meaning, then acpmux's reasons in its words.
    static func banner(_ reasons: String) -> String {
        String(format: String(localized: "hostPressure.banner", defaultValue: "This Mac is overloaded: %@", table: "HostPressure", bundle: .module.inAppLanguage),
               reasons)
    }

    static var showDetails: String {
        String(localized: "hostPressure.showDetails", defaultValue: "Show Details", table: "HostPressure", bundle: .module.inAppLanguage)
    }

    static var openActivity: String {
        String(localized: "hostPressure.openActivity", defaultValue: "Open Agent Activity", table: "HostPressure", bundle: .module.inAppLanguage)
    }

    /// A pressure gauge's name (cmux-host-budget `gauges.rs` kinds); an unknown kind shows as it came.
    static func gaugeName(_ kind: String) -> String {
        switch kind {
        case "cpu": String(localized: "hostPressure.gauge.cpu", defaultValue: "CPU", table: "HostPressure", bundle: .module.inAppLanguage)
        case "memory": String(localized: "hostPressure.gauge.memory", defaultValue: "Memory", table: "HostPressure", bundle: .module.inAppLanguage)
        case "tokens": String(localized: "hostPressure.gauge.tokens", defaultValue: "Tokens", table: "HostPressure", bundle: .module.inAppLanguage)
        case "cache": String(localized: "hostPressure.gauge.cache", defaultValue: "Cache", table: "HostPressure", bundle: .module.inAppLanguage)
        case "mac_slots": String(localized: "hostPressure.gauge.macSlots", defaultValue: "Mac slots", table: "HostPressure", bundle: .module.inAppLanguage)
        default: kind
        }
    }
}
