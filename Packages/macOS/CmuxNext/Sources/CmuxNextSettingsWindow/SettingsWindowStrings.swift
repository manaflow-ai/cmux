import Foundation

/// Swift text of this module (Localizable.xcstrings here). The React Settings page reads the
/// same catalog (`settingsWindow.*`, webviews/scripts/pages/gen-strings.mjs), so its keys stay.
/// Setting titles live with the schema in CmuxNextSettings.
nonisolated enum SettingsWindowStrings {
    static var windowTitle: String { text("settingsWindow.title", "Settings") }
    static var reset: String { text("settingsWindow.reset", "Reset") }
    static func seconds(_ value: String) -> String { format("settingsWindow.seconds", "%@ s", value) }
    static func points(_ value: String) -> String { format("settingsWindow.points", "%@ pt", value) }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ args: any CVarArg...) -> String {
        String(format: text(key, value), locale: Locale.current, arguments: args)
    }
}
