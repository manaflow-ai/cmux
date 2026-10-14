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
        .workspaceRow: Rows(top: [.action("renameWorkspace"), .action("palette.toggleWorkspacePin"), .choices("palette.workspaceColor"),
                                  .action("workspace.newBelow")],
                            group: [.choices("moveWorkspaceToGroup"), .action("groupSelectedWorkspaces"), .action("removeWorkspaceFromGroup")],
                            close: ["closeWorkspace"]),
        .tab: Rows(top: [.action("tab.restart"), .action("renameTab"), .action("palette.toggleTabPin"), .action("newTab.toRight"),
                         .action("duplicateTab")],
                   group: [.action("tabGroup.create"), .action("tabGroup.addTab"), .action("tabGroup.removeTab")],
                   close: ["closeTab"]),
        .pane: Rows(top: [.action("splitRight"), .action("splitDown"), .action("toggleSplitZoom"), .action("renamePane")],
                    close: ["closePane"]),
    ]

    /// `entries` (a whole generated menu) as its essential rows, its group section, More, and
    /// its close rows. A listed row the menu does not place is left out.
    static func apply(_ rows: Rows, to entries: [ContextMenuEntry]) -> [ContextMenuEntry] {
        let placed = Set(ContextMenuCatalog.referencedIDs(entries))
        let keep = { (entry: ContextMenuEntry) in ContextMenuCatalog.referencedIDs([entry]).allSatisfy(placed.contains) }
        let top = rows.top.filter(keep), group = rows.group.filter(keep)
        let close = rows.close.filter(placed.contains)
        // referencedIDs counts a choices row's trailer, so More drops New Group with Move to Group.
        let rest = ContextMenuCatalog.removing(Set(ContextMenuCatalog.referencedIDs(top + group) + close), from: entries)
        let more: [ContextMenuEntry] = rest.contains { if case .separator = $0 { false } else { true } } ? [.folder(.more, rest)] : []
        let groupSection: [ContextMenuEntry] = group.isEmpty ? [] : [.separator] + group + [.separator]
        return top + groupSection + more + [.separator] + close.map(ContextMenuEntry.action)
    }
}
