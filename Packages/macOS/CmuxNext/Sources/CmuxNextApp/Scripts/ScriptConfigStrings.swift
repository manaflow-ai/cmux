import Foundation

/// App strings for config scripts (table ScriptConfig.xcstrings).
enum ScriptConfigStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ScriptConfig", bundle: .module)
    }

    static var reload: String { t("scriptConfig.reload", "Reload Config Scripts") }
    static var notServed: String { t("scriptConfig.notServed", "This cmux does not run config scripts yet. Restart cmux to update it.") }
    static func failed(_ message: String) -> String { String(format: t("scriptConfig.failed", "Config script: %@"), message) }
    static func enterMode(_ title: String) -> String { String(format: t("scriptConfig.enterMode", "Key Mode: %@"), title) }
    static var exitMode: String { t("scriptConfig.exitMode", "Exit Key Mode") }
}
