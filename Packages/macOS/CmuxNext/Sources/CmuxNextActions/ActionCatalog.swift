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
        // Go to Tab… became Search Tabs (one tab list); with a tab target it
        // still focuses that tab.
        "palette.goToTab": "tab.search",
        // The link menu's Open Link in New Tab (R123): keybindings and scripts keep working.
        "openLinkInNewTab": "browser.link.openInNewTab",
        // Browser profile placeholders from before browser profiles existed.
        "browserNewProfile": "browserProfile.new",
        "browserRenameProfile": "browserProfile.rename",
        // Rooms became Spaces (Leo, 2026-10-02): keybindings and scripts keep working.
        "browserProfile.clearRoomDefault": "browserProfile.clearSpaceDefault",
        "browserProfile.setRoomDefault": "browserProfile.setSpaceDefault",
        "room.clearColor": "space.clearColor",
        "room.clearIcon": "space.clearIcon",
        "room.clearTheme": "space.clearTheme",
        "room.color.blue": "space.color.blue",
        "room.color.cyan": "space.color.cyan",
        "room.color.green": "space.color.green",
        "room.color.grey": "space.color.grey",
        "room.color.orange": "space.color.orange",
        "room.color.pink": "space.color.pink",
        "room.color.purple": "space.color.purple",
        "room.color.red": "space.color.red",
        "room.color.yellow": "space.color.yellow",
        "room.delete": "space.delete",
        "room.move": "space.move",
        "room.moveLeft": "space.moveLeft",
        "room.moveRight": "space.moveRight",
        "room.new": "space.new",
        "room.newWindow": "space.newWindow",
        "room.newWorkspace": "space.newWorkspace",
        "room.next": "space.next",
        "room.previous": "space.previous",
        "room.rename": "space.rename",
        "room.selectByNumber": "space.selectByNumber",
        "room.setColor": "space.setColor",
        "room.setDefaults": "space.setDefaults",
        "room.setIcon": "space.setIcon",
        "room.setTheme": "space.setTheme",
        "room.switch": "space.switch",
        "sidebar.section.toggleRoomScope": "sidebar.section.toggleSpaceScope",
        "workspace.duplicateToRoom": "workspace.duplicateToSpace",
        "workspace.moveToRoom": "workspace.moveToSpace",
        "workspaceGroup.moveToRoom": "workspaceGroup.moveToSpace",
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
        HomeActionCatalog.self,
        TabGroupActionCatalog.self,
        ScreenActionCatalog.self,
        ScreenGroupActionCatalog.self,
        TerminalActionCatalog.self,
        BrowserActionCatalog.self,
        BrowserToolbarActionCatalog.self,
        BrowserChromeActionCatalog.self,
        BrowserHitActionCatalog.self,
        ViewerActionCatalog.self,
        FilePageActionCatalog.self,
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
        TasksActionCatalog.self,
        LinkActionCatalog.self,
        ServerActionCatalog.self,
        MarkdownPageActionCatalog.self,
        ListActionCatalog.self,
        PaletteKeyActionCatalog.self,
    ]

    private static func makeAll() -> [ActionDescriptor] {
        var all: [ActionDescriptor] = []
        for group in groups { all += group.descriptors() }
        for index in all.indices where focusActionIDs.contains(all[index].id) { all[index].focuses = true }
        return ActionSurfaceCatalog.apply(to: all).withLeaderChords()
    }
}

extension ActionRegistry {
    /// A registry seeded with the full cmux catalog and legacy aliases.
    public static func standard() -> ActionRegistry {
        ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
    }
}
