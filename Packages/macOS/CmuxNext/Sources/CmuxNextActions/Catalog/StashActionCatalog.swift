// Stash (a native OneTab; the daemon's `stash-v1`): Save and Close puts browser tabs, whole
// workspaces (terminals too, `stash-workspaces-v1`), a workspace group or a window's workspaces
// away in one stashed group, and the Stashed Tabs page brings them back. No default shortcuts.
// Every surface decision is here (`surfacePlan`). Titles live in StashActions.xcstrings.

nonisolated enum StashActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            // On one of several selected tabs, every selected one (`tabSelectionTitle`: Save and Close Tabs).
            tabAction("tab.stash", title: t("action.stash.tab", "Save and Close Tab"), symbol: "tray.and.arrow.down",
                      cliName: "tab stash", rank: 605),
            tabAction("tab.stashToRight", title: t("action.stash.toRight", "Save and Close Tabs to the Right"),
                      symbol: "arrow.right.to.line.compact", cliName: "tab stash-to-right", rank: 606),
            tabAction("tab.stashOthers", title: t("action.stash.others", "Save and Close Other Tabs"), symbol: "tray.full",
                      cliName: "tab stash-others", rank: 607),
            // On one of several selected sidebar rows, every selected one (`WindowMembershipHandlers.rowTargets`).
            ActionDescriptor(
                id: "workspace.stash", title: t("action.stash.workspace", "Save and Close Workspace"),
                keywords: keywords("workspace", "terminals"), category: .workspace, symbol: "tray.and.arrow.down",
                surfaces: [.palette, .contextMenu], targets: [.workspace], cliName: "workspace stash", destructive: true,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ActionSurfaceCatalog.p(.workspaceRow, .close, 506, folder: .close)])
            ),
            ActionDescriptor(
                id: "workspaceGroup.stash", title: t("action.stash.workspaceGroup", "Save and Close Group"),
                keywords: keywords("group", "workspaces"), category: .workspace, symbol: "tray.2",
                surfaces: [.palette, .contextMenu], targets: [.workspaceGroup], cliName: "workspace-group stash", destructive: true,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ActionSurfaceCatalog.p(.workspaceGroup, .close, 504, folder: .options)])
            ),
            // A row's menu takes the window that lists the row, as Close All Workspaces does.
            ActionDescriptor(
                id: "window.stash", title: t("action.stash.window", "Save and Close All Workspaces"),
                keywords: keywords("window", "all", "workspaces"), category: .workspace, symbol: "tray.full",
                surfaces: [.palette, .menu, .contextMenu], arguments: [CatalogArgument.windowWindow.optional],
                cliName: "window stash", mainMenu: .file, destructive: true,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ActionSurfaceCatalog.p(.workspaceRow, .close, 507, folder: .close)])
            ),
            ActionDescriptor(
                id: "stash.show", title: t("action.stash.show", "Show Stashed Tabs"),
                keywords: ["stash", "stashed", "onetab", "saved", "save for later", "tabs", "restore", "cmux://stashed"],
                category: .window, symbol: "tray.full", surfaces: [.palette, .menu], cliName: "stash show", mainMenu: .window,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "stash.importOneTab", title: t("action.stash.importOneTab", "Import from OneTab…"),
                keywords: ["stash", "onetab", "import", "paste", "tabs"], category: .window, symbol: "square.and.arrow.down",
                surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
        ]
    }

    /// A Save and Close row of the tab menu, in its Close folder (under More).
    private static func tabAction(_ id: ActionID, title: String, symbol: String, cliName: String, rank: Int) -> ActionDescriptor {
        ActionDescriptor(
            id: id, title: title, keywords: keywords("tab", "browser", "page"), category: .tab, symbol: symbol,
            surfaces: [.palette, .contextMenu], targets: [.tab], cliName: cliName,
            surfacePlan: ActionSurfacePlan(cli: .offered, contextMenus: [ActionSurfaceCatalog.p(.tab, .close, rank, folder: .close)])
        )
    }

    private static func keywords(_ extra: String...) -> [String] {
        ["stash", "save", "close", "later", "onetab", "put away"] + extra
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "StashActions", bundle: .module)
    }
}
