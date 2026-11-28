import CmuxNextCompat
import Foundation

/// The pressure gauges' names (`HostPressureGauges.xcstrings`); the numbers behind each come from
/// cmux-host-budget `gauges.rs` in its words.
enum HostPressureGaugeStrings {
    /// A gauge's name by its `kind`; an unknown kind shows as it came.
    static func name(_ kind: String) -> String {
        switch kind {
        case "cpu": String(localized: "hostPressure.gauge.cpu", defaultValue: "CPU", table: "HostPressureGauges", bundle: .module.inAppLanguage)
        case "memory": String(localized: "hostPressure.gauge.memory", defaultValue: "Memory", table: "HostPressureGauges", bundle: .module.inAppLanguage)
        case "tokens": String(localized: "hostPressure.gauge.tokens", defaultValue: "Tokens", table: "HostPressureGauges", bundle: .module.inAppLanguage)
        case "cache": String(localized: "hostPressure.gauge.cache", defaultValue: "Cache", table: "HostPressureGauges", bundle: .module.inAppLanguage)
        case "mac_slots": String(localized: "hostPressure.gauge.macSlots", defaultValue: "Mac slots", table: "HostPressureGauges", bundle: .module.inAppLanguage)
        default: kind
        }
    }
}
