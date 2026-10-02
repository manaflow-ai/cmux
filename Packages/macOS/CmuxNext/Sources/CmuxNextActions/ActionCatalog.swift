/// The canonical action catalog: one descriptor per row of the old app's
/// action inventory (plans/cmux-next/inventory.md section 1) plus the tab
/// group and workspace group families (plans/cmux-next/architecture.md
/// section 7), one `ActionCatalogGroup` per domain in
/// `Catalog/<Domain>ActionCatalog.swift`. IDs match `KeyboardShortcutSettings.Action` raw values where one existed
/// (users store them in `cmux.json` `shortcuts`), else the old palette
/// command ID, else a new stable ID.
public nonisolated enum ActionCatalog {
    /// Every catalog descriptor, in inventory order.
    public static let all: [ActionDescriptor] = makeAll()

    /// IDs used by the cmux-next scaffold before the catalog existed, mapped
    /// to their canonical catalog ID. The registry folds these on register
    /// and lookup so older call sites keep working.
    public static let legacyAliases: [ActionID: ActionID] = [
        "app.quit": "quit",
        "tab.new": "newSurface",
        "tab.close": "closeTab",
        "tab.next": "nextSurface",
        "tab.previous": "prevSurface",
        "view.toggleSidebar": "toggleSidebar",
        "palette.show": "commandPalette",
        // Browser profile placeholders from before browser profiles existed.
        "browserNewProfile": "browserProfile.new",
        "browserRenameProfile": "browserProfile.rename",
    ]

    /// The catalog's domain groups, in inventory order. `all` concatenates
    /// their descriptors in this order, which menu ranks tie-break on.
    static let groups: [any ActionCatalogGroup.Type] = [
        WindowActionCatalog.self,
        WorkspaceActionCatalog.self,
        WorkspaceVerbActionCatalog.self,
        WorkspaceGroupActionCatalog.self,
        ProfileActionCatalog.self,
        ThemeActionCatalog.self,
        PaneActionCatalog.self,
        TabActionCatalog.self,
        ResourceActionCatalog.self,
        TabGroupActionCatalog.self,
        ScreenActionCatalog.self,
        ScreenGroupActionCatalog.self,
        TerminalActionCatalog.self,
        BrowserActionCatalog.self,
        PageInfoActionCatalog.self,
        ExtensionActionCatalog.self,
        BrowserProfileActionCatalog.self,
        SidebarActionCatalog.self,
        NotificationActionCatalog.self,
        AgentActionCatalog.self,
        CloudActionCatalog.self,
        AccountActionCatalog.self,
        RemoteActionCatalog.self,
        SettingsActionCatalog.self,
        HibernationActionCatalog.self,
        LayoutActionCatalog.self,
        HistoryActionCatalog.self,
        BookmarkActionCatalog.self,
        SidebarSectionActionCatalog.self,
        AppStoreActionCatalog.self,
    ]

    private static func makeAll() -> [ActionDescriptor] {
        var all: [ActionDescriptor] = []
        for group in groups { all += group.descriptors() }
        return ActionSurfaceCatalog.apply(to: all)
    }
}
