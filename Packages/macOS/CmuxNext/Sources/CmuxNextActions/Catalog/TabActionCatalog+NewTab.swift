import Foundation

nonisolated extension TabActionCatalog {
    /// `newTab.submit`'s arguments (plans/cmux-next/new-tab.md section 5):
    /// what the new tab field would get, with its Search | Ask mode and agent.
    static var newTabSubmitArguments: [ActionArgument] {
        [
            ActionArgument(name: "text", title: t("argument.newTab.text", "Text"), kind: .string),
            ActionArgument(name: "mode", title: t("argument.newTab.mode", "Search or Ask"), kind: .enumeration([
                ActionEnumCase(value: "search", title: t("argument.newTab.mode.search", "Search")),
                ActionEnumCase(value: "ask", title: t("argument.newTab.mode.ask", "Ask")),
            ]), isRequired: false),
            ActionArgument(name: "agent", title: t("argument.newTab.agent", "Agent"), kind: .string, isRequired: false),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "NewTabActions", bundle: .module)
    }
}
