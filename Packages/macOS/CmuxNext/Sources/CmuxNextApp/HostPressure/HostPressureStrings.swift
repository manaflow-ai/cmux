import Foundation

/// The host pressure indicator's and popover's text (`HostPressure.xcstrings`). acpmux's
/// reasons (`over`) are shown in its own words.
enum HostPressureStrings {
    static var warningTitle: String {
        String(localized: "hostPressure.title.warning", defaultValue: "This Mac is busy", table: "HostPressure", bundle: .module)
    }

    static var criticalTitle: String {
        String(localized: "hostPressure.title.critical", defaultValue: "This Mac is overloaded", table: "HostPressure", bundle: .module)
    }

    static var warnOnly: String {
        String(localized: "hostPressure.warnOnly", defaultValue: "cmux only warns. Nothing is paused or stopped.",
               table: "HostPressure", bundle: .module)
    }

    /// The 1-minute load and the budget's limit, both already formatted.
    static func load(_ load: String, limit: String) -> String {
        String(format: String(localized: "hostPressure.load", defaultValue: "Load %1$@, limit %2$@", table: "HostPressure", bundle: .module),
               load, limit)
    }

    static var turns: String {
        String(localized: "hostPressure.turns", defaultValue: "Turns", table: "HostPressure", bundle: .module)
    }

    static var processes: String {
        String(localized: "hostPressure.processes", defaultValue: "Processes", table: "HostPressure", bundle: .module)
    }

    static var sessions: String {
        String(localized: "hostPressure.sessions", defaultValue: "Busiest sessions", table: "HostPressure", bundle: .module)
    }

    static var stop: String {
        String(localized: "hostPressure.stop", defaultValue: "Stop", table: "HostPressure", bundle: .module)
    }

    static func stopTitle(_ name: String) -> String {
        String(format: String(localized: "hostPressure.stop.title", defaultValue: "Stop %@?", table: "HostPressure", bundle: .module), name)
    }

    static var stopBody: String {
        String(localized: "hostPressure.stop.body", defaultValue: "Its agent stops now. The chat stays, and a new message resumes it.",
               table: "HostPressure", bundle: .module)
    }

    /// The critical banner: the title's meaning, then acpmux's reasons in its words.
    static func banner(_ reasons: String) -> String {
        String(format: String(localized: "hostPressure.banner", defaultValue: "This Mac is overloaded: %@", table: "HostPressure", bundle: .module),
               reasons)
    }

    static var showDetails: String {
        String(localized: "hostPressure.showDetails", defaultValue: "Show Details", table: "HostPressure", bundle: .module)
    }

    static var openActivity: String {
        String(localized: "hostPressure.openActivity", defaultValue: "Open Agent Activity", table: "HostPressure", bundle: .module)
    }
}
