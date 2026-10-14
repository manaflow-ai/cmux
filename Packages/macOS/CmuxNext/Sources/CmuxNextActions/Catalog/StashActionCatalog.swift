// Stash (a native OneTab; the daemon's `stash-v1`): close browser tabs into a
// named group and bring them back from the Stashed page. Browser tabs only;
// no default shortcuts. Titles live in StashActions.xcstrings.

nonisolated enum StashActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            tabAction("tab.stash", title: t("action.stash.tab", "Stash Tab"), symbol: "tray.and.arrow.down",
                      keywords: ["stash", "onetab", "save", "later", "close", "tab", "browser"]),
            tabAction("tab.stashToRight", title: t("action.stash.toRight", "Stash Tabs to the Right"),
                      symbol: "arrow.right.to.line.compact", keywords: ["stash", "onetab", "save", "later", "close", "right"]),
            tabAction("tab.stashOthers", title: t("action.stash.others", "Stash Other Tabs"), symbol: "tray.full",
                      keywords: ["stash", "onetab", "save", "later", "close", "other"]),
            tabAction("workspace.stash", title: t("action.stash.workspace", "Stash Workspace"), symbol: "tray.2",
                      keywords: ["stash", "onetab", "save", "later", "close", "workspace", "pages"]),
            ActionDescriptor(
                id: "stash.show", title: t("action.stash.show", "Show Stashed Tabs"),
                keywords: ["stash", "stashed", "onetab", "saved", "tabs", "restore"], category: .window,
                symbol: "tray.full", surfaces: [.palette], cliName: "history stashed"
            ),
            ActionDescriptor(
                id: "stash.importOneTab", title: t("action.stash.importOneTab", "Import from OneTab…"),
                keywords: ["stash", "onetab", "import", "paste", "tabs"], category: .window,
                symbol: "square.and.arrow.down", surfaces: [.palette], cliName: "history import-onetab"
            ),
        ]
    }

    private static func tabAction(_ id: ActionID, title: String, symbol: String, keywords: [String]) -> ActionDescriptor {
        ActionDescriptor(id: id, title: title, keywords: keywords, category: .tab, symbol: symbol,
                         surfaces: [.palette, .contextMenu], targets: [.tab])
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "StashActions", bundle: .module)
    }
}
