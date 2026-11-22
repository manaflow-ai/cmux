import CmuxNextDesign
import Foundation

/// Chrome text of the Debug Settings window (Localizable.xcstrings in this
/// module). Tunable labels and help are English developer text declared
/// with the tunables (DEV and NIGHTLY builds only).
nonisolated enum DebugSettingsStrings {
    static var windowTitle: String { text("debugSettings.title", "Debug Settings") }
    static var searchPlaceholder: String { text("debugSettings.search", "Search tunables") }
    static var all: String { text("debugSettings.all", "All") }
    static var changed: String { text("debugSettings.changed", "Changed") }
    static var copyJSON: String { text("debugSettings.copyJSON", "Copy Changed as JSON") }
    static var copySwift: String { text("debugSettings.copySwift", "Copy as Swift Defaults") }
    static var resetSection: String { text("debugSettings.resetSection", "Reset Section") }
    static var resetAll: String { text("debugSettings.resetAll", "Reset All") }
    static var noResults: String { text("debugSettings.noResults", "No tunables match.") }
    static var nothingChanged: String { text("debugSettings.nothingChanged", "Nothing differs from the defaults.") }
    static var didResetAll: String { text("debugSettings.didResetAll", "Every tunable is back to its default.") }
    static var on: String { text("debugSettings.on", "On") }
    static var off: String { text("debugSettings.off", "Off") }
    static var response: String { text("debugSettings.response", "Response") }
    static var damping: String { text("debugSettings.damping", "Damping") }
    static var footer: String {
        text("debugSettings.footer", "Changes apply live and persist for this build. Defaults stay in code: copy the changed values for an agent to bake in.")
    }
    static func defaultIs(_ value: String) -> String { format("debugSettings.defaultIs", "Default: %@", value) }
    static func copiedJSON(_ count: Int) -> String { format("debugSettings.copiedJSON", "Copied changed values as JSON (%lld).", count) }
    static func copiedSwift(_ count: Int) -> String { format("debugSettings.copiedSwift", "Copied Swift defaults (%lld).", count) }
    static func didReset(_ section: String) -> String { format("debugSettings.didReset", "Reset %@.", section) }
    static func count(_ count: Int) -> String { format("debugSettings.count", "%lld tunables", count) }

    /// A value for display: numbers with their unit, springs as response
    /// and damping, choices and colors by name.
    static func display(_ value: TunableValue, kind: TunableKind) -> String {
        switch value {
        case .number(let number):
            guard case .number(_, _, let unit) = kind else { return TunableExport.format(number) }
            return formatted(number, unit: unit)
        case .bool(let flag): return flag ? on : off
        case .choice(let raw):
            if case .choice(let options) = kind, let option = options.first(where: { $0.value == raw }) { return option.title }
            return raw
        case .color(let color): return color.rawValue
        case .spring(let spring): return "\(TunableExport.format(spring.response)) s / \(TunableExport.format(spring.dampingFraction))"
        }
    }

    static func formatted(_ number: Double, unit: TunableUnit) -> String {
        let text = TunableExport.format(number)
        switch unit {
        case .points: return SettingsWindowStrings.points(text)
        case .seconds: return SettingsWindowStrings.seconds(text)
        case .fraction: return TunableExport.format((number * 1000).rounded() / 10) + "%"
        case .multiplier: return text + "×"
        case .pointsPerSecond: return SettingsWindowStrings.points(text) + "/s"
        case .count: return text
        }
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ args: any CVarArg...) -> String {
        String(format: text(key, value), locale: Locale.current, arguments: args)
    }
}
