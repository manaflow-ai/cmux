// Browser tab hibernation (plans/cmux-next/tab-lifecycle.md): the
// `browser.hibernation` setting and the per-tab Hibernate / Wake commands.
// Titles live in HibernationActions.xcstrings.

nonisolated extension ActionCatalog {
    static func hibernationActions() -> [ActionDescriptor] {
        [
            setting("browser.hibernation.off", title: t("action.hibernation.off", "Turn Off Tab Hibernation"), symbol: "moon.zzz",
                    keywords: ["browser", "hibernation", "memory", "saver", "discard", "sleep", "off", "disable"],
                    cli: "settings turn-off-tab-hibernation"),
            setting("browser.hibernation.moderate", title: t("action.hibernation.moderate", "Hibernate Hidden Tabs After 1 Hour"),
                    symbol: "moon", keywords: ["browser", "hibernation", "memory", "saver", "discard", "sleep", "moderate"],
                    cli: "settings use-moderate-tab-hibernation"),
            setting("browser.hibernation.aggressive", title: t("action.hibernation.aggressive", "Hibernate Hidden Tabs After 10 Minutes"),
                    symbol: "moon.fill", keywords: ["browser", "hibernation", "memory", "saver", "discard", "sleep", "aggressive"],
                    cli: "settings use-aggressive-tab-hibernation"),
            ActionDescriptor(
                id: "hibernateTab", title: t("action.hibernateTab", "Hibernate Tab"),
                keywords: ["tab", "browser", "hibernate", "sleep", "discard", "memory", "saver"], category: .tab, symbol: "moon.zzz",
                surfaces: [.palette, .contextMenu], targets: [.tab], cliName: "tab hibernate"
            ),
            ActionDescriptor(
                id: "wakeTab", title: t("action.wakeTab", "Wake Tab"),
                keywords: ["tab", "browser", "wake", "restore", "hibernate", "reload"], category: .tab, symbol: "sun.max",
                surfaces: [.palette, .contextMenu], targets: [.tab], cliName: "tab wake"
            ),
        ]
    }

    private static func setting(_ id: ActionID, title: String, symbol: String, keywords: [String], cli: String) -> ActionDescriptor {
        ActionDescriptor(id: id, title: title, keywords: keywords, category: .settings, symbol: symbol, surfaces: [.palette], cliName: cli)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "HibernationActions", bundle: .module)
    }
}
