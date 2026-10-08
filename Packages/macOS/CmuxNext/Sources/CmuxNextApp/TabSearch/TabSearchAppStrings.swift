import Foundation

/// App strings for Search Tabs (table TabSearch.xcstrings).
nonisolated enum TabSearchAppStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "TabSearch", bundle: .module)
    }

    static var tabGone: String { t("tabSearch.refusal.tabGone", "That tab is no longer open") }
    static var needsFocus: String {
        t("tabSearch.refusal.needsFocus", "Search Tabs opens only when focus is requested; read results with tabs.search")
    }

    static func window(_ number: Int) -> String {
        String(localized: "tabSearch.window", defaultValue: "Window \(number)", table: "TabSearch", bundle: .module)
    }
}
