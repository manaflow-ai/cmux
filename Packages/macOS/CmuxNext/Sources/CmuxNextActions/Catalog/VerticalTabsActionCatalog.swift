// Vertical tabs (Leo 2026-10-20: "a per-workspace Vertical tabs option, off by default, and a Use
// vertical tabs for all workspaces control"), and the menu of a tab bar's empty area (the strip's or
// the vertical list's), modeled on Edge's and Chrome's vertical-tab menus: New Tab, Reopen Closed Tab,
// Bookmark All Tabs, Move All Tabs to a New Workspace; the vertical tabs rows; Task Manager. The
// rows other catalogs own are placed in `tabStrip` in ActionSurfaceCatalog+Menus.swift. Titles live
// in SettingsActions.xcstrings.

nonisolated enum VerticalTabsActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            // The workspace's own choice; the row reads Turn Off Vertical Tabs while its tabs are vertical.
            ActionDescriptor(
                id: "tabs.verticalTabs.toggle", title: t("action.tabs.verticalTabs.toggle", "Turn On Vertical Tabs"),
                keywords: ["vertical", "tabs", "list", "side", "horizontal", "strip", "workspace", "edge", "chrome"],
                category: .tab, symbol: "sidebar.left", surfaces: [.palette, .keyboard, .contextMenu],
                targets: [.pane], cliName: "pane toggle-vertical-tabs",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ContextMenuPlacement(.tabStrip, .view, 0)])
            ),
            // `tabs.verticalTabs` (Settings: Use Vertical Tabs for All Workspaces); checked while on.
            ActionDescriptor(
                id: "tabs.verticalTabs.allWorkspaces", title: t("action.tabs.verticalTabs.allWorkspaces", "Use Vertical Tabs for All Workspaces"),
                keywords: ["vertical", "tabs", "all", "every", "workspaces", "default", "list", "horizontal", "setting"],
                category: .settings, symbol: "rectangle.stack", surfaces: [.palette, .contextMenu],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenus: [ContextMenuPlacement(.tabStrip, .view, 1)])
            ),
            // Chrome's Collapse Tabs: vertical lists show icons only; Expand Tabs while collapsed.
            ActionDescriptor(
                id: "tabs.verticalTabs.collapse", title: t("action.tabs.verticalTabs.collapse", "Collapse Tabs"),
                keywords: ["vertical", "tabs", "collapse", "expand", "icons", "narrow", "list"],
                category: .tab, symbol: "arrow.left.to.line", surfaces: [.palette, .keyboard, .contextMenu],
                targets: [.pane],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenus: [ContextMenuPlacement(.tabStrip, .view, 2)])
            ),
            // `tabs.verticalTabsExpandOnHover` (Chrome's Turn off Auto Expanding Tabs); checked while on.
            ActionDescriptor(
                id: "tabs.verticalTabs.expandOnHover", title: t("action.tabs.verticalTabs.expandOnHover", "Auto-Expand Tabs on Hover"),
                keywords: ["vertical", "tabs", "collapse", "expand", "hover", "auto", "icons", "setting"],
                category: .settings, symbol: "cursorarrow.motionlines", surfaces: [.palette, .contextMenu],
                targets: [.pane],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenus: [ContextMenuPlacement(.tabStrip, .view, 3)])
            ),
        ]
    }

    /// Menu-only titles of other catalogs' rows in the tab bar's menu (Edge's words).
    static var reopenClosedTabLabel: String { t("menu.tabStrip.reopenClosedTab", "Reopen Closed Tab") }
    static var moveAllTabsToNewWorkspaceLabel: String { t("menu.tabStrip.moveAllTabsToNewWorkspace", "Move All Tabs to a New Workspace") }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "SettingsActions", bundle: .module)
    }
}
