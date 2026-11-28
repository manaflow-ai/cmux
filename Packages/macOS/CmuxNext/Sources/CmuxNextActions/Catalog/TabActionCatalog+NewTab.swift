import Foundation

nonisolated extension TabActionCatalog {
    /// `newTab.submit`'s arguments (plans/cmux-next/new-tab.md section 5):
    /// what the new tab field would get, the explicit web-search choice (one
    /// input without a mode, R86) and the agent.
    static var newTabSubmitArguments: [ActionArgument] {
        [
            ActionArgument(name: "text", title: t("argument.newTab.text", "Text"), kind: .string),
            ActionArgument(name: "search", title: t("argument.newTab.search", "Search the Web"), kind: .bool, isRequired: false),
            ActionArgument(name: "agent", title: t("argument.newTab.agent", "Agent"), kind: .string, isRequired: false),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "NewTabActions", bundle: .module)
    }
}
