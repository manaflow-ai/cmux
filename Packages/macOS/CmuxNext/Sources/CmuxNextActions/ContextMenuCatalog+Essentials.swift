/// The few rows a crowded right-click menu keeps at its top level (Leo 2026-10-11: the
/// workspace menu's twelve rows were "overwhelming"). Every other row of that menu moves into
/// one More submenu, in its old order with its folders inside; the close rows end the menu
/// after a separator. The group rows stay at the top level in their own section (Lawrence
/// 2026-10-14: "my groups UI is lost"); More never takes them.
nonisolated enum ContextMenuEssentials {
    struct Rows {
        /// The top-level rows, in order.
        let top: [ContextMenuEntry]
        /// The group rows: one top-level section after `top`, between separators.
        var group: [ContextMenuEntry] = []
        let close: [ActionID]
    }

    /// A choices row that always ends with this action, so its submenu shows with no choices
    /// too: Move to Group lists the groups, then New Group.
    static let choiceTrailers: [ActionID: ActionID] = ["moveWorkspaceToGroup": "workspace.moveToNewGroup"]

    static let menus: [ActionMenuContext: Rows] = [
        // Move ▸ (Up, Down, Top, Bottom of the group, …) stays at the top level (u2418: "I need an
        // option to … move a workspace to the top of a group"; under More it was not found).
        .workspaceRow: Rows(top: [.action("renameWorkspace"), .action("palette.toggleWorkspacePin"), .choices("palette.workspaceColor"),
                                  .action("workspace.newBelow"), .folder(.move, [])],
                            group: [.choices("moveWorkspaceToGroup"), .action("groupSelectedWorkspaces"), .action("removeWorkspaceFromGroup")],
                            close: ["closeWorkspace"]),
        // Chrome's tab menu, in its order (`TabMenuModel::Build`, Leo 2026-10-19: "make sure that
        // chrome right click tab situation works"): New Tab to the Right and the group rows; Reload,
        // Duplicate, Pin, Mute; More; then Close Tab, Close Other Tabs and Close Tabs to the Right.
        // A page-only row (Reload, Mute) leaves a terminal's menu. The 12-row cap
        // (everyMenuKeepsAShortTopLevel, Lawrence 2026-10-01) leaves Chrome's Move Tab to New
        // Window in More > Move, with cmux's Rename, Back to Pinned Page and Restart (the dead
        // tab's overlay also has Restart).
        .tab: Rows(top: [.action("newTab.toRight"), .action("tabGroup.create"), .action("tabGroup.addTab"), .action("tabGroup.removeTab"),
                         .separator,
                         .action("reloadTab"), .action("duplicateTab"), .action("palette.toggleTabPin"), .action("toggleTabAudioMute")],
                   close: ["closeTab", "closeOtherTabsInPane", "closeTabsToRight"]),
        // Split Left and Split Up sit in Split beside Split Right and Split Down (menu audit S1).
        .pane: Rows(top: [.action("splitRight"), .action("splitDown"), .folder(.split, []), .action("toggleSplitZoom"), .action("renamePane")],
                    close: ["closePane"]),
    ]

    /// `entries` (a whole generated menu) as its essential rows, its group section, More, and
    /// its close rows. A listed row the menu does not place is left out; a listed folder is
    /// the menu's generated folder of that kind (left out when the menu has none).
    static func apply(_ rows: Rows, to entries: [ContextMenuEntry]) -> [ContextMenuEntry] {
        let placed = Set(ContextMenuCatalog.referencedIDs(entries))
        let keep = { (entry: ContextMenuEntry) in ContextMenuCatalog.referencedIDs([entry]).allSatisfy(placed.contains) }
        let top = rows.top.compactMap { generated($0, in: entries) }.filter(keep), group = rows.group.filter(keep)
        let close = rows.close.filter(placed.contains)
        // referencedIDs counts a choices row's trailer, so More drops New Group with Move to Group.
        // A section whose rows all went to the top leaves no empty section behind in More.
        let rest = collapsingSeparators(ContextMenuCatalog.removing(Set(ContextMenuCatalog.referencedIDs(top + group) + close), from: entries))
        let more: [ContextMenuEntry] = rest.isEmpty ? [] : [.folder(.more, rest)]
        let groupSection: [ContextMenuEntry] = group.isEmpty ? [] : [.separator] + group + [.separator]
        return top + groupSection + more + [.separator] + close.map(ContextMenuEntry.action)
    }

    /// A listed folder as the menu's own folder of that kind, with its rows; other rows as listed.
    private static func generated(_ entry: ContextMenuEntry, in entries: [ContextMenuEntry]) -> ContextMenuEntry? {
        guard case .folder(let folder, _) = entry else { return entry }
        for case .folder(folder, let children) in entries { return .folder(folder, children) }
        return nil
    }

    /// `entries` with one separator between sections, none at the ends, inside folders too.
    private static func collapsingSeparators(_ entries: [ContextMenuEntry]) -> [ContextMenuEntry] {
        var result: [ContextMenuEntry] = []
        for entry in entries {
            switch entry {
            case .separator:
                if let last = result.last, last != ContextMenuEntry.separator { result.append(entry) }
            case .folder(let folder, let children):
                result.append(.folder(folder, collapsingSeparators(children)))
            default:
                result.append(entry)
            }
        }
        while case .separator? = result.last { result.removeLast() }
        return result
    }
}
