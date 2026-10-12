/// The few rows a crowded right-click menu keeps at its top level (Leo 2026-10-11: the
/// workspace menu's twelve rows were "overwhelming"). Every other row of that menu moves into
/// one More submenu, in its old order with its folders inside; the close rows end the menu
/// after a separator.
nonisolated enum ContextMenuEssentials {
    struct Rows {
        /// The top-level rows, in order.
        let top: [ContextMenuEntry]
        let close: [ActionID]
    }

    static let menus: [ActionMenuContext: Rows] = [
        .workspaceRow: Rows(top: [.action("renameWorkspace"), .action("palette.toggleWorkspacePin"), .choices("palette.workspaceColor"),
                                  .action("workspace.newBelow"), .choices("moveWorkspaceToGroup")],
                            close: ["closeWorkspace"]),
        .tab: Rows(top: [.action("tab.restart"), .action("renameTab"), .action("palette.toggleTabPin"),
                         .action("browser.resetPinnedTab"), .action("newTab.toRight"), .action("duplicateTab")],
                   close: ["closeTab"]),
        .pane: Rows(top: [.action("splitRight"), .action("splitDown"), .action("toggleSplitZoom"), .action("renamePane")],
                    close: ["closePane"]),
    ]

    /// `entries` (a whole generated menu) as its essential rows, More, and its close rows.
    /// A listed row the menu does not place is left out.
    static func apply(_ rows: Rows, to entries: [ContextMenuEntry]) -> [ContextMenuEntry] {
        let placed = Set(ContextMenuCatalog.referencedIDs(entries))
        let top = rows.top.filter { ContextMenuCatalog.referencedIDs([$0]).allSatisfy(placed.contains) }
        let close = rows.close.filter(placed.contains)
        let rest = ContextMenuCatalog.removing(Set(ContextMenuCatalog.referencedIDs(top) + close), from: entries)
        let more: [ContextMenuEntry] = rest.contains { if case .separator = $0 { false } else { true } } ? [.folder(.more, rest)] : []
        return top + more + [.separator] + close.map(ContextMenuEntry.action)
    }
}
