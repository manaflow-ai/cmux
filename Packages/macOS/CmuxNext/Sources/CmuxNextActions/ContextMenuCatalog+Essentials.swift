/// The few rows a crowded right-click menu keeps at its top level (Leo 2026-10-11: the
/// workspace menu's twelve rows were "overwhelming"). Every other row of that menu moves into
/// one More submenu, in its old order; its short folders show there as sections, its long ones
/// as submenus (`inlineFolderLimit`). The close rows end the menu
/// after a separator. The group rows stay at the top level in their own section (Lawrence
/// 2026-10-14: "my groups UI is lost"); More never takes them.
nonisolated enum ContextMenuEssentials {
    struct Rows {
        /// The top-level rows, in order.
        let top: [ContextMenuEntry]
        /// The group rows: one top-level section after `top`, between separators.
        var group: [ContextMenuEntry] = []
        let close: [ActionID]
        /// The rows after the close rows, behind a separator (Chrome's Reopen Closed Tab).
        var tail: [ActionID] = []
    }

    /// A choices row that always ends with this action, so its submenu shows with no choices
    /// too: Move to Group lists the groups, then New Group.
    static let choiceTrailers: [ActionID: ActionID] = ["moveWorkspaceToGroup": "workspace.moveToNewGroup"]

    static let menus: [ActionMenuContext: Rows] = [
        // Move ▸ (Up, Down, Top, Bottom of the group, …) stays at the top level (u2418: "I need an
        // option to … move a workspace to the top of a group"; under More it was not found).
        // Send Message… (u5402: "send messages in the iMessage UI via right clicking") opens the
        // Chief's chat about this workspace.
        // Rename and the color row open the menu as its name field and swatches (MenuIdentityHeader,
        // Leo 2026-10-20: "like Chrome"). Duplicate joins the top level from More's New.
        .workspaceRow: Rows(top: [.action("renameWorkspace"), .action("palette.toggleWorkspacePin"), .choices("palette.workspaceColor"),
                                  .action("workspace.newBelow"), .action("workspace.duplicate"), .action("home.messageAbout"), .folder(.move, [])],
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

    /// The workspace menu opened on one of several selected rows, as Chrome's menu on several
    /// selected tabs (Leo 2026-10-20): New Workspace Below and Group Selected Workspaces (the Cmd-Shift-G action); Duplicate, Move ▸,
    /// Pin and Mute; More; then Close Workspaces, Close Other Workspaces and Close Workspaces Below,
    /// which keep the selection (`WorkspaceBulkClose.keeping`); then Reopen Closed Workspace. Its
    /// rows act on every selected row (`WindowMembershipHandlers.rowTargets`) and say so
    /// (`NSMenu.namingWorkspaceSelection`).
    static let selectionMenus: [ActionMenuContext: Rows] = [
        // The color row becomes the header's swatches, which color every selected row (MenuIdentityHeader).
        .workspaceRow: Rows(top: [.choices("palette.workspaceColor"), .action("workspace.newBelow"), .action("groupSelectedWorkspaces"), .separator,
                                  .action("workspace.duplicate"), .folder(.move, []), .action("palette.toggleWorkspacePin"),
                                  .action("workspace.toggleAudioMute"), .separator],
                            close: ["closeWorkspace", "palette.closeOtherWorkspaces", "palette.closeWorkspacesBelow"],
                            tail: ["reopenClosedWorkspace"]),
    ]

    /// `entries` (a whole generated menu) as its essential rows, its group section, More, and
    /// its close rows. A listed row the menu does not place is left out; a listed folder is
    /// the menu's generated folder of that kind (left out when the menu has none).
    static func apply(_ rows: Rows, to entries: [ContextMenuEntry]) -> [ContextMenuEntry] {
        let placed = Set(ContextMenuCatalog.referencedIDs(entries))
        let keep = { (entry: ContextMenuEntry) in ContextMenuCatalog.referencedIDs([entry]).allSatisfy(placed.contains) }
        let top = rows.top.compactMap { generated($0, in: entries) }.filter(keep), group = rows.group.filter(keep)
        let close = rows.close.filter(placed.contains), tail = rows.tail.filter(placed.contains)
        // referencedIDs counts a choices row's trailer, so More drops New Group with Move to Group.
        // A section whose rows all went to the top leaves no empty section behind in More.
        let shown = Set(ContextMenuCatalog.referencedIDs(top + group) + close + tail)
        let rest = collapsingSeparators(inliningShortFolders(ContextMenuCatalog.removing(shown, from: entries)))
        let more: [ContextMenuEntry] = rest.isEmpty ? [] : [.folder(.more, rest)]
        let groupSection: [ContextMenuEntry] = group.isEmpty ? [] : [.separator] + group + [.separator]
        let tailSection: [ContextMenuEntry] = tail.isEmpty ? [] : [.separator] + tail.map(ContextMenuEntry.action)
        return top + groupSection + more + [.separator] + close.map(ContextMenuEntry.action) + tailSection
    }

    /// The most rows a folder inside More may have and still show as a section of More, between
    /// separators, rather than a submenu of its own (Leo 2026-10-20: flatten "More ›"; a longer
    /// folder stays one submenu so More fits a laptop screen).
    static let inlineFolderLimit = 8

    /// More's top-level folders with at most `inlineFolderLimit` rows as sections, longer ones as
    /// they were.
    private static func inliningShortFolders(_ entries: [ContextMenuEntry]) -> [ContextMenuEntry] {
        entries.flatMap { entry -> [ContextMenuEntry] in
            guard case .folder(_, let children) = entry, ContextMenuCatalog.referencedIDs(children).count <= inlineFolderLimit else { return [entry] }
            return [.separator] + children + [.separator]
        }
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
