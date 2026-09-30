/// The canonical action catalog: one descriptor per row of the old app's
/// action inventory (plans/cmux-next/inventory.md section 1) plus the tab
/// group and workspace group families (plans/cmux-next/architecture.md
/// section 7), split by domain across `ActionCatalog+<Domain>.swift`. IDs
/// match `KeyboardShortcutSettings.Action` raw values where one existed
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
    ]

    private static func makeAll() -> [ActionDescriptor] {
        var all: [ActionDescriptor] = []
        all += windowActions()
        all += workspaceActions()
        all += workspaceVerbActions()
        all += workspaceGroupsActions()
        all += profileActions()
        all += paneActions()
        all += tabActions()
        all += resourceActions()
        all += tabGroupsActions()
        all += terminalActions()
        all += browserActions()
        all += pageInfoActions()
        all += extensionActions()
        all += sidebarActions()
        all += notificationsActions()
        all += agentsActions()
        all += cloudActions()
        all += settingsActions()
        all += layoutActions()
        return all
    }
}
