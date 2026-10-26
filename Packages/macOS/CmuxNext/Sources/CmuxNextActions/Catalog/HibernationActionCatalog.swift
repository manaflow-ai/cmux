// Browser tab hibernation (plans/cmux-next/tab-lifecycle.md): the
// `browser.hibernation` setting and the per-tab Hibernate / Wake commands.
// Titles live in HibernationActions.xcstrings.

nonisolated enum HibernationActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            setting("browser.hibernation.off", title: t("action.hibernation.off", "Turn Off Tab Hibernation"), symbol: "moon.zzz",
                    keywords: ["browser", "hibernation", "memory", "saver", "discard", "sleep", "off", "disable"],
                    cli: "settings turn-off-tab-hibernation"),
            setting("browser.hibernation.moderate", title: t("action.hibernation.moderate30", "Hibernate Hidden Tabs After 30 Minutes"),
                    symbol: "moon", keywords: ["browser", "hibernation", "memory", "saver", "discard", "sleep", "moderate"],
                    cli: "settings use-moderate-tab-hibernation"),
            setting("browser.hibernation.aggressive", title: t("action.hibernation.aggressive", "Hibernate Hidden Tabs After 10 Minutes"),
                    symbol: "moon.fill", keywords: ["browser", "hibernation", "memory", "saver", "discard", "sleep", "aggressive"],
                    cli: "settings use-aggressive-tab-hibernation"),
            setting("browser.keepNeighborTabsAwake.0", title: t("action.neighborTabs.off", "Don't Keep Neighbor Tabs Awake"),
                    symbol: "rectangle.stack", keywords: neighborKeywords + ["off", "disable"],
                    cli: "settings keep-no-neighbor-tabs-awake"),
            setting("browser.keepNeighborTabsAwake.1", title: t("action.neighborTabs.one", "Keep 1 Neighbor Tab Awake on Each Side"),
                    symbol: "rectangle.stack.fill", keywords: neighborKeywords + ["1", "one"],
                    cli: "settings keep-1-neighbor-tab-awake"),
            setting("browser.keepNeighborTabsAwake.2", title: t("action.neighborTabs.two", "Keep 2 Neighbor Tabs Awake on Each Side"),
                    symbol: "rectangle.stack.fill", keywords: neighborKeywords + ["2", "two"],
                    cli: "settings keep-2-neighbor-tabs-awake"),
            setting("browser.keepNeighborTabsAwake.3", title: t("action.neighborTabs.three", "Keep 3 Neighbor Tabs Awake on Each Side"),
                    symbol: "rectangle.stack.fill", keywords: neighborKeywords + ["3", "three"],
                    cli: "settings keep-3-neighbor-tabs-awake"),
            ActionDescriptor(
                id: "hibernateTab", title: t("action.hibernateTab", "Hibernate Tab"),
                keywords: ["tab", "browser", "hibernate", "sleep", "discard", "memory", "saver"], category: .tab, symbol: "moon.zzz",
                surfaces: [.palette, .contextMenu], targets: [.tab], cliName: "tab hibernate"
            ),
            ActionDescriptor(
                id: "neverHibernateSite", title: t("action.neverHibernateSite", "Never Hibernate This Site"),
                keywords: ["tab", "browser", "hibernate", "sleep", "discard", "exception", "exclude", "site", "keep", "awake"],
                category: .tab, symbol: "moon.circle", surfaces: [.palette, .contextMenu], targets: [.tab],
                cliName: "tab never-hibernate-site"
            ),
            ActionDescriptor(
                id: "wakeTab", title: t("action.wakeTab", "Wake Tab"),
                keywords: ["tab", "browser", "wake", "restore", "hibernate", "reload"], category: .tab, symbol: "sun.max",
                surfaces: [.palette, .contextMenu], targets: [.tab], cliName: "tab wake"
            ),
        ]
    }

    private static let neighborKeywords = ["browser", "tabs", "neighbor", "adjacent", "warm", "preload", "instant", "switch", "hibernation", "freeze"]

    private static func setting(_ id: ActionID, title: String, symbol: String, keywords: [String], cli: String) -> ActionDescriptor {
        ActionDescriptor(id: id, title: title, keywords: keywords, category: .settings, symbol: symbol, surfaces: [.palette], cliName: cli)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "HibernationActions", bundle: .module)
    }
}
