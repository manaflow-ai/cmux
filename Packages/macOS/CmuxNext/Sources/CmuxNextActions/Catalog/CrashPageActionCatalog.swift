// The crash page's Reload All Tabs after the Chromium Host ended (behavior audit 4, P8): every Chromium
// tab lost its page with the host, so one action brings them back, the shown ones now and the hidden ones
// when they show. The crash page's own button runs it. Title in PageInfoActions.xcstrings. No CLI verb
// (so no MCP tool): a script reloads a tab with `cmux browser reload`.

nonisolated enum CrashPageActionCatalog: ActionCatalogGroup {
    /// The catalog id.
    static let reloadAllTabsID: ActionID = "browser.crashPage.reloadAllTabs"

    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: reloadAllTabsID,
                title: String(localized: "action.crashPage.reloadAllTabs", defaultValue: "Reload All Tabs After Chromium Stopped",
                              table: "PageInfoActions", bundle: .module),
                keywords: ["reload", "all", "tabs", "chromium", "crash", "stopped", "sad tab", "restore", "recover"],
                category: .browser, symbol: "arrow.clockwise", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
        ]
    }
}
