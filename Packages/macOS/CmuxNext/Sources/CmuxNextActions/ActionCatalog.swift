// Generated from the action table in plans/cmux-next/inventory.md section 1.
// Edit entries here directly; keep titles in Localizable.xcstrings (en, ja) in sync.

/// The canonical action catalog: one descriptor per row of the old app's
/// action inventory. IDs match `KeyboardShortcutSettings.Action` raw values
/// where one existed (users store them in `cmux.json` `shortcuts`), else the
/// old palette command ID, else a new stable ID for context-menu-only rows.
public enum ActionCatalog {
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

    // One function per category keeps type checking fast.
    private static func makeAll() -> [ActionDescriptor] {
        windowActions() + workspaceActions() + paneActions() + tabActions() + terminalActions() + browserActions() + sidebarActions() + notificationsActions() + agentsActions() + cloudActions() + settingsActions()
    }

    private static func windowActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "openSettings",
                title: String(localized: "action.openSettings", defaultValue: "Settings…", bundle: .module),
                keywords: ["preferences", "options", "config"],
                defaultShortcut: Shortcut(",", modifiers: [.command]),
                category: .window,
                symbol: "gearshape",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "newWindow",
                title: String(localized: "action.newWindow", defaultValue: "New Window", bundle: .module),
                keywords: ["open"],
                defaultShortcut: Shortcut("n", modifiers: [.command, .shift]),
                category: .window,
                symbol: "macwindow.badge.plus",
                surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "closeWindow",
                title: String(localized: "action.closeWindow", defaultValue: "Close Window", bundle: .module),
                defaultShortcut: Shortcut("w", modifiers: [.control, .command]),
                category: .window,
                symbol: "xmark.rectangle",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "toggleFullScreen",
                title: String(localized: "action.toggleFullScreen", defaultValue: "Toggle Full Screen", bundle: .module),
                keywords: ["fullscreen", "maximize"],
                defaultShortcut: Shortcut("f", modifiers: [.control, .command]),
                category: .window,
                symbol: "arrow.up.left.and.arrow.down.right",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "quit",
                title: String(localized: "action.quit", defaultValue: "Quit cmux", bundle: .module),
                keywords: ["exit", "close"],
                defaultShortcut: Shortcut("q", modifiers: [.command]),
                category: .window,
                symbol: "power",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "showHideAllWindows",
                title: String(localized: "action.showHideAllWindows", defaultValue: "Show/Hide All Windows", bundle: .module),
                keywords: ["global", "hotkey", "summon"],
                defaultShortcut: Shortcut(".", modifiers: [.control, .option, .command]),
                category: .window,
                symbol: "macwindow.on.rectangle",
                surfaces: [.keyboard]
            ),
            ActionDescriptor(
                id: "globalSearch",
                title: String(localized: "action.globalSearch", defaultValue: "Search All Windows…", bundle: .module),
                keywords: ["find", "global"],
                defaultShortcut: Shortcut("f", modifiers: [.option, .command]),
                category: .window,
                symbol: "magnifyingglass",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "commandPalette",
                title: String(localized: "action.commandPalette", defaultValue: "Command Palette…", bundle: .module),
                keywords: ["actions", "commands", "search"],
                defaultShortcut: Shortcut("p", modifiers: [.command, .shift]),
                category: .window,
                symbol: "command",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "commandPaletteNext",
                title: String(localized: "action.commandPaletteNext", defaultValue: "Palette: Select Next Item", bundle: .module),
                defaultShortcut: Shortcut("n", modifiers: [.control]),
                category: .window,
                symbol: "chevron.down",
                surfaces: [.keyboard],
                requires: [.paletteOpen]
            ),
            ActionDescriptor(
                id: "commandPalettePrevious",
                title: String(localized: "action.commandPalettePrevious", defaultValue: "Palette: Select Previous Item", bundle: .module),
                defaultShortcut: Shortcut("p", modifiers: [.control]),
                category: .window,
                symbol: "chevron.up",
                surfaces: [.keyboard],
                requires: [.paletteOpen]
            ),
            ActionDescriptor(
                id: "goToWorkspace",
                title: String(localized: "action.goToWorkspace", defaultValue: "Go to Workspace…", bundle: .module),
                keywords: ["switch", "jump", "switcher"],
                defaultShortcut: Shortcut("p", modifiers: [.command]),
                category: .window,
                symbol: "arrow.right.square",
                surfaces: [.keyboard, .menu],
                input: .list
            ),
            ActionDescriptor(
                id: "focusHistoryBack",
                title: String(localized: "action.focusHistoryBack", defaultValue: "Focus Back", bundle: .module),
                keywords: ["history", "previous"],
                defaultShortcut: Shortcut("[", modifiers: [.command]),
                category: .window,
                symbol: "chevron.backward",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "focusHistoryForward",
                title: String(localized: "action.focusHistoryForward", defaultValue: "Focus Forward", bundle: .module),
                keywords: ["history", "next"],
                defaultShortcut: Shortcut("]", modifiers: [.command]),
                category: .window,
                symbol: "chevron.forward",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "focusHistoryLast",
                title: String(localized: "action.focusHistoryLast", defaultValue: "Focus Last", bundle: .module),
                keywords: ["history", "toggle", "recent"],
                category: .window,
                symbol: "arrow.uturn.backward",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "recentlyFocused",
                title: String(localized: "action.recentlyFocused", defaultValue: "Recently Focused…", bundle: .module),
                keywords: ["history"],
                category: .window,
                symbol: "clock",
                surfaces: [.menu],
                input: .list
            ),
            ActionDescriptor(
                id: "recentlyClosed",
                title: String(localized: "action.recentlyClosed", defaultValue: "Recently Closed…", bundle: .module),
                keywords: ["history", "reopen", "undo"],
                category: .window,
                symbol: "clock.arrow.circlepath",
                surfaces: [.menu],
                input: .list
            ),
            ActionDescriptor(
                id: "palette.openTaskManager",
                title: String(localized: "action.palette.openTaskManager", defaultValue: "Task Manager", bundle: .module),
                keywords: ["processes", "cpu", "memory", "activity"],
                category: .window,
                symbol: "gauge.with.dots.needle.33percent",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "palette.sleepyMode",
                title: String(localized: "action.palette.sleepyMode", defaultValue: "Sleepy Mode", bundle: .module),
                keywords: ["idle", "pause", "battery"],
                category: .window,
                symbol: "moon.zzz",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "keepMacAwake",
                title: String(localized: "action.keepMacAwake", defaultValue: "Keep Mac Awake", bundle: .module),
                keywords: ["caffeinate", "sleep"],
                category: .window,
                symbol: "cup.and.saucer",
                surfaces: [.menu]
            ),
            ActionDescriptor(
                id: "showMainWindow",
                title: String(localized: "action.showMainWindow", defaultValue: "Show cmux", bundle: .module),
                keywords: ["open", "window"],
                category: .window,
                symbol: "macwindow",
                surfaces: [.menu]
            ),
            ActionDescriptor(
                id: "about",
                title: String(localized: "action.about", defaultValue: "About cmux", bundle: .module),
                keywords: ["version"],
                category: .window,
                symbol: "info.circle",
                surfaces: [.menu]
            ),
            ActionDescriptor(
                id: "taskManager.killProcess",
                title: String(localized: "action.taskManager.killProcess", defaultValue: "Kill Process…", bundle: .module),
                keywords: ["terminate", "signal"],
                category: .window,
                symbol: "xmark.octagon",
                surfaces: [.contextMenu],
                input: .list
            ),
        ]
    }

    private static func workspaceActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "newTab",
                title: String(localized: "action.newTab", defaultValue: "New Workspace", bundle: .module),
                keywords: ["create", "add"],
                defaultShortcut: Shortcut("n", modifiers: [.command]),
                category: .workspace,
                symbol: "plus.rectangle.on.rectangle",
                surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "newBrowserWorkspace",
                title: String(localized: "action.newBrowserWorkspace", defaultValue: "New Browser Workspace", bundle: .module),
                keywords: ["web", "create"],
                defaultShortcut: Shortcut("n", modifiers: [.option, .command]),
                category: .workspace,
                symbol: "globe",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "openFolder",
                title: String(localized: "action.openFolder", defaultValue: "Open Folder…", bundle: .module),
                keywords: ["directory", "project"],
                defaultShortcut: Shortcut("o", modifiers: [.command]),
                category: .workspace,
                symbol: "folder",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "palette.openFolderInVSCodeInline",
                title: String(localized: "action.palette.openFolderInVSCodeInline", defaultValue: "Open Folder in VS Code (Inline)…", bundle: .module),
                keywords: ["editor", "code"],
                category: .workspace,
                symbol: "chevron.left.forwardslash.chevron.right",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "reopenPreviousSession",
                title: String(localized: "action.reopenPreviousSession", defaultValue: "Restore Previous App Launch", bundle: .module),
                keywords: ["session", "restore"],
                defaultShortcut: Shortcut("o", modifiers: [.command, .shift]),
                category: .workspace,
                symbol: "clock.arrow.circlepath",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "reopenClosedWorkspace",
                title: String(localized: "action.reopenClosedWorkspace", defaultValue: "Reopen Closed Workspace", bundle: .module),
                keywords: ["undo", "restore"],
                category: .workspace,
                symbol: "arrow.uturn.backward.square",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "nextSidebarTab",
                title: String(localized: "action.nextSidebarTab", defaultValue: "Next Workspace", bundle: .module),
                keywords: ["switch"],
                defaultShortcut: Shortcut("]", modifiers: [.control, .command]),
                category: .workspace,
                symbol: "chevron.down.square",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "prevSidebarTab",
                title: String(localized: "action.prevSidebarTab", defaultValue: "Previous Workspace", bundle: .module),
                keywords: ["switch"],
                defaultShortcut: Shortcut("[", modifiers: [.control, .command]),
                category: .workspace,
                symbol: "chevron.up.square",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "nextSidebarTabInGroup",
                title: String(localized: "action.nextSidebarTabInGroup", defaultValue: "Next Workspace in Group", bundle: .module),
                keywords: ["switch"],
                category: .workspace,
                symbol: "chevron.down.circle",
                surfaces: [.keyboard]
            ),
            ActionDescriptor(
                id: "prevSidebarTabInGroup",
                title: String(localized: "action.prevSidebarTabInGroup", defaultValue: "Previous Workspace in Group", bundle: .module),
                keywords: ["switch"],
                category: .workspace,
                symbol: "chevron.up.circle",
                surfaces: [.keyboard]
            ),
            ActionDescriptor(
                id: "moveWorkspaceUp",
                title: String(localized: "action.moveWorkspaceUp", defaultValue: "Move Workspace Up", bundle: .module),
                keywords: ["reorder"],
                defaultShortcut: Shortcut("[", modifiers: [.control, .option, .command]),
                category: .workspace,
                symbol: "arrow.up",
                surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "moveWorkspaceDown",
                title: String(localized: "action.moveWorkspaceDown", defaultValue: "Move Workspace Down", bundle: .module),
                keywords: ["reorder"],
                defaultShortcut: Shortcut("]", modifiers: [.control, .option, .command]),
                category: .workspace,
                symbol: "arrow.down",
                surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.moveWorkspaceToTop",
                title: String(localized: "action.palette.moveWorkspaceToTop", defaultValue: "Move Workspace to Top", bundle: .module),
                keywords: ["reorder"],
                category: .workspace,
                symbol: "arrow.up.to.line",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "selectWorkspaceByNumber",
                title: String(localized: "action.selectWorkspaceByNumber", defaultValue: "Select Workspace 1…9", bundle: .module),
                keywords: ["switch", "index"],
                defaultShortcut: Shortcut("1", modifiers: [.command]),
                shortcutFamily: .digits,
                category: .workspace,
                symbol: "number",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "moveWorkspaceToWindow",
                title: String(localized: "action.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window…", bundle: .module),
                keywords: ["window"],
                category: .workspace,
                symbol: "macwindow.and.cursorarrow",
                surfaces: [.menu, .contextMenu],
                input: .list
            ),
            ActionDescriptor(
                id: "renameWorkspace",
                title: String(localized: "action.renameWorkspace", defaultValue: "Rename Workspace…", bundle: .module),
                keywords: ["title", "name"],
                defaultShortcut: Shortcut("r", modifiers: [.command, .shift]),
                category: .workspace,
                symbol: "pencil",
                surfaces: [.palette, .keyboard, .menu, .contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "palette.clearWorkspaceName",
                title: String(localized: "action.palette.clearWorkspaceName", defaultValue: "Clear Workspace Name", bundle: .module),
                keywords: ["title", "name", "reset"],
                category: .workspace,
                symbol: "pencil.slash",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "editWorkspaceDescription",
                title: String(localized: "action.editWorkspaceDescription", defaultValue: "Edit Workspace Description…", bundle: .module),
                keywords: ["notes", "summary"],
                defaultShortcut: Shortcut("e", modifiers: [.option, .command]),
                category: .workspace,
                symbol: "text.alignleft",
                surfaces: [.palette, .keyboard, .menu, .contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "palette.clearWorkspaceDescription",
                title: String(localized: "action.palette.clearWorkspaceDescription", defaultValue: "Clear Workspace Description", bundle: .module),
                keywords: ["notes", "reset"],
                category: .workspace,
                symbol: "text.badge.xmark",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "markWorkspaceDone",
                title: String(localized: "action.markWorkspaceDone", defaultValue: "Mark Workspace as Done", bundle: .module),
                keywords: ["complete", "status", "todo"],
                defaultShortcut: Shortcut(";", modifiers: [.command]),
                category: .workspace,
                symbol: "checkmark.circle",
                surfaces: [.palette, .keyboard, .contextMenu]
            ),
            ActionDescriptor(
                id: "cycleWorkspaceStatus",
                title: String(localized: "action.cycleWorkspaceStatus", defaultValue: "Cycle Workspace Status", bundle: .module),
                keywords: ["status", "todo"],
                defaultShortcut: Shortcut(";", modifiers: [.command, .shift]),
                category: .workspace,
                symbol: "circle.dashed",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "palette.workspaceStatus",
                title: String(localized: "action.palette.workspaceStatus", defaultValue: "Set Workspace Status…", bundle: .module),
                keywords: ["status", "todo", "auto"],
                category: .workspace,
                symbol: "circle.lefthalf.filled",
                surfaces: [.palette, .contextMenu],
                input: .list
            ),
            ActionDescriptor(
                id: "palette.addWorkspaceChecklistItem",
                title: String(localized: "action.palette.addWorkspaceChecklistItem", defaultValue: "Add Checklist Item…", bundle: .module),
                keywords: ["todo", "task"],
                category: .workspace,
                symbol: "checklist",
                surfaces: [.palette, .contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "toggleChecklistItemComplete",
                title: String(localized: "action.toggleChecklistItemComplete", defaultValue: "Toggle Checklist Item Complete", bundle: .module),
                keywords: ["todo", "task"],
                defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: [.command]),
                category: .workspace,
                symbol: "checkmark.square",
                surfaces: [.keyboard]
            ),
            ActionDescriptor(
                id: "palette.openWorkspaceTodoPane",
                title: String(localized: "action.palette.openWorkspaceTodoPane", defaultValue: "Open Todo Pane", bundle: .module),
                keywords: ["checklist", "task"],
                category: .workspace,
                symbol: "list.bullet.rectangle",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "closeWorkspace",
                title: String(localized: "action.closeWorkspace", defaultValue: "Close Workspace", bundle: .module),
                keywords: ["remove"],
                defaultShortcut: Shortcut("w", modifiers: [.command, .shift]),
                category: .workspace,
                symbol: "xmark.square",
                surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.closeOtherWorkspaces",
                title: String(localized: "action.palette.closeOtherWorkspaces", defaultValue: "Close Other Workspaces", bundle: .module),
                keywords: ["remove"],
                category: .workspace,
                symbol: "xmark.square.fill",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.closeWorkspacesBelow",
                title: String(localized: "action.palette.closeWorkspacesBelow", defaultValue: "Close Workspaces Below", bundle: .module),
                keywords: ["remove"],
                category: .workspace,
                symbol: "arrow.down.to.line",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.closeWorkspacesAbove",
                title: String(localized: "action.palette.closeWorkspacesAbove", defaultValue: "Close Workspaces Above", bundle: .module),
                keywords: ["remove"],
                category: .workspace,
                symbol: "arrow.up.to.line",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.toggleWorkspacePin",
                title: String(localized: "action.palette.toggleWorkspacePin", defaultValue: "Pin/Unpin Workspace", bundle: .module),
                keywords: ["pin", "unpin", "favorite"],
                category: .workspace,
                symbol: "pin",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.markWorkspaceRead",
                title: String(localized: "action.palette.markWorkspaceRead", defaultValue: "Mark Workspace as Read", bundle: .module),
                keywords: ["read", "notifications"],
                category: .workspace,
                symbol: "envelope.open",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.markWorkspaceUnread",
                title: String(localized: "action.palette.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread", bundle: .module),
                keywords: ["unread", "notifications"],
                category: .workspace,
                symbol: "envelope.badge",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.workspaceColor",
                title: String(localized: "action.palette.workspaceColor", defaultValue: "Set Workspace Color…", bundle: .module),
                keywords: ["color", "tint"],
                category: .workspace,
                symbol: "paintpalette",
                surfaces: [.palette, .contextMenu],
                input: .list
            ),
            ActionDescriptor(
                id: "palette.workspaceCustomColor",
                title: String(localized: "action.palette.workspaceCustomColor", defaultValue: "Custom Workspace Color…", bundle: .module),
                keywords: ["color", "tint"],
                category: .workspace,
                symbol: "eyedropper",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.resetWorkspaceColor",
                title: String(localized: "action.palette.resetWorkspaceColor", defaultValue: "Reset Workspace Color", bundle: .module),
                keywords: ["color", "tint"],
                category: .workspace,
                symbol: "paintbrush",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "reconnectWorkspace",
                title: String(localized: "action.reconnectWorkspace", defaultValue: "Reconnect Workspace", bundle: .module),
                keywords: ["ssh", "remote"],
                category: .workspace,
                symbol: "arrow.triangle.2.circlepath",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "disconnectWorkspace",
                title: String(localized: "action.disconnectWorkspace", defaultValue: "Disconnect Workspace", bundle: .module),
                keywords: ["ssh", "remote"],
                category: .workspace,
                symbol: "bolt.horizontal.circle",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "copyWorkspaceSSHError",
                title: String(localized: "action.copyWorkspaceSSHError", defaultValue: "Copy SSH Error", bundle: .module),
                keywords: ["ssh", "remote", "error"],
                category: .workspace,
                symbol: "exclamationmark.bubble",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "clearWorkspaceNotifications",
                title: String(localized: "action.clearWorkspaceNotifications", defaultValue: "Clear Workspace Notifications", bundle: .module),
                keywords: ["notifications"],
                category: .workspace,
                symbol: "bell.slash",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "revealWorkspaceInFinder",
                title: String(localized: "action.revealWorkspaceInFinder", defaultValue: "Show Workspace in Finder", bundle: .module),
                keywords: ["finder", "reveal", "directory"],
                category: .workspace,
                symbol: "folder.badge.gearshape",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "palette.copyWorkspaceID",
                title: String(localized: "action.palette.copyWorkspaceID", defaultValue: "Copy Workspace ID", bundle: .module),
                keywords: ["identifier", "uuid"],
                category: .workspace,
                symbol: "doc.on.doc",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.copyWorkspaceIDAndRef",
                title: String(localized: "action.palette.copyWorkspaceIDAndRef", defaultValue: "Copy Workspace ID and Ref", bundle: .module),
                keywords: ["identifier", "ref"],
                category: .workspace,
                symbol: "doc.on.doc",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.copyWorkspaceLink",
                title: String(localized: "action.palette.copyWorkspaceLink", defaultValue: "Copy Workspace Link", bundle: .module),
                keywords: ["url", "deeplink"],
                category: .workspace,
                symbol: "link",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "newWorkspaceGroup",
                title: String(localized: "action.newWorkspaceGroup", defaultValue: "New Workspace Group", bundle: .module),
                keywords: ["group", "create"],
                defaultShortcut: Shortcut("g", modifiers: [.control, .command]),
                category: .workspace,
                symbol: "folder.badge.plus",
                surfaces: [.keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "groupSelectedWorkspaces",
                title: String(localized: "action.groupSelectedWorkspaces", defaultValue: "Group Selected Workspaces", bundle: .module),
                keywords: ["group"],
                defaultShortcut: Shortcut("g", modifiers: [.command, .shift]),
                category: .workspace,
                symbol: "square.stack.3d.up",
                surfaces: [.palette, .keyboard, .contextMenu]
            ),
            ActionDescriptor(
                id: "toggleFocusedWorkspaceGroupCollapsed",
                title: String(localized: "action.toggleFocusedWorkspaceGroupCollapsed", defaultValue: "Toggle Group Collapse", bundle: .module),
                keywords: ["group", "expand", "collapse"],
                defaultShortcut: Shortcut(".", modifiers: [.control, .command]),
                category: .workspace,
                symbol: "chevron.up.chevron.down",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "moveWorkspaceToGroup",
                title: String(localized: "action.moveWorkspaceToGroup", defaultValue: "Move Workspace to Group…", bundle: .module),
                keywords: ["group"],
                category: .workspace,
                symbol: "folder.badge.questionmark",
                surfaces: [.contextMenu],
                input: .list
            ),
            ActionDescriptor(
                id: "removeWorkspaceFromGroup",
                title: String(localized: "action.removeWorkspaceFromGroup", defaultValue: "Remove Workspace from Group", bundle: .module),
                keywords: ["group", "ungroup"],
                category: .workspace,
                symbol: "folder.badge.minus",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.newWorkspace",
                title: String(localized: "action.group.newWorkspace", defaultValue: "New Workspace in Group", bundle: .module),
                keywords: ["group", "create"],
                category: .workspace,
                symbol: "plus.square.dashed",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.rename",
                title: String(localized: "action.group.rename", defaultValue: "Rename Group…", bundle: .module),
                keywords: ["group", "title"],
                category: .workspace,
                symbol: "pencil.line",
                surfaces: [.contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "group.togglePin",
                title: String(localized: "action.group.togglePin", defaultValue: "Pin/Unpin Group", bundle: .module),
                keywords: ["group"],
                category: .workspace,
                symbol: "pin.circle",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.markRead",
                title: String(localized: "action.group.markRead", defaultValue: "Mark Group as Read", bundle: .module),
                keywords: ["group", "notifications"],
                category: .workspace,
                symbol: "envelope.open.fill",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.markUnread",
                title: String(localized: "action.group.markUnread", defaultValue: "Mark Group as Unread", bundle: .module),
                keywords: ["group", "notifications"],
                category: .workspace,
                symbol: "envelope.badge.fill",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.clearNotifications",
                title: String(localized: "action.group.clearNotifications", defaultValue: "Clear Group Notifications", bundle: .module),
                keywords: ["group", "notifications"],
                category: .workspace,
                symbol: "bell.slash.fill",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.ungroup",
                title: String(localized: "action.group.ungroup", defaultValue: "Ungroup Workspaces", bundle: .module),
                keywords: ["group"],
                category: .workspace,
                symbol: "rectangle.stack.badge.minus",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.delete",
                title: String(localized: "action.group.delete", defaultValue: "Delete Group", bundle: .module),
                keywords: ["group", "remove"],
                category: .workspace,
                symbol: "trash",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.editConfig",
                title: String(localized: "action.group.editConfig", defaultValue: "Edit Group Config…", bundle: .module),
                keywords: ["group", "config", "cmux.json"],
                category: .workspace,
                symbol: "slider.horizontal.3",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "saveLayoutTemplate",
                title: String(localized: "action.saveLayoutTemplate", defaultValue: "Save Layout as Template…", bundle: .module),
                keywords: ["layout", "template"],
                defaultShortcut: Shortcut("s", modifiers: [.control, .command]),
                category: .workspace,
                symbol: "square.and.arrow.down",
                surfaces: [.palette, .keyboard, .contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "palette.layout.open",
                title: String(localized: "action.palette.layout.open", defaultValue: "New Workspace from Template…", bundle: .module),
                keywords: ["layout", "template"],
                category: .workspace,
                symbol: "square.grid.2x2",
                surfaces: [.palette, .contextMenu],
                input: .list
            ),
            ActionDescriptor(
                id: "manageLayouts",
                title: String(localized: "action.manageLayouts", defaultValue: "Manage Layout Templates…", bundle: .module),
                keywords: ["layout", "template", "delete", "default"],
                category: .workspace,
                symbol: "square.grid.3x3.square",
                surfaces: [.contextMenu],
                input: .list
            ),
            ActionDescriptor(
                id: "palette.openWorkspacePullRequests",
                title: String(localized: "action.palette.openWorkspacePullRequests", defaultValue: "Open All Workspace PR Links", bundle: .module),
                keywords: ["github", "pull request"],
                category: .workspace,
                symbol: "arrow.triangle.pull",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.findWork",
                title: String(localized: "action.palette.findWork", defaultValue: "Find Work", bundle: .module),
                keywords: ["current work", "tasks"],
                category: .workspace,
                symbol: "sparkle.magnifyingglass",
                surfaces: [.palette]
            ),
        ]
    }

    private static func paneActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "splitRight",
                title: String(localized: "action.splitRight", defaultValue: "Split Right", bundle: .module),
                keywords: ["pane", "vertical"],
                defaultShortcut: Shortcut("d", modifiers: [.command]),
                category: .pane,
                symbol: "rectangle.split.2x1",
                surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "splitDown",
                title: String(localized: "action.splitDown", defaultValue: "Split Down", bundle: .module),
                keywords: ["pane", "horizontal"],
                defaultShortcut: Shortcut("d", modifiers: [.command, .shift]),
                category: .pane,
                symbol: "rectangle.split.1x2",
                surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "newPaneAutoLayout",
                title: String(localized: "action.newPaneAutoLayout", defaultValue: "New Pane (Auto Layout)", bundle: .module),
                keywords: ["split", "pane"],
                defaultShortcut: Shortcut("n", modifiers: [.control, .command]),
                category: .pane,
                symbol: "rectangle.badge.plus",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "toggleSplitZoom",
                title: String(localized: "action.toggleSplitZoom", defaultValue: "Toggle Pane Zoom", bundle: .module),
                keywords: ["maximize", "zoom"],
                defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: [.command, .shift]),
                category: .pane,
                symbol: "arrow.up.left.and.down.right.magnifyingglass",
                surfaces: [.palette, .keyboard, .contextMenu]
            ),
            ActionDescriptor(
                id: "equalizeSplits",
                title: String(localized: "action.equalizeSplits", defaultValue: "Equalize Splits", bundle: .module),
                keywords: ["balance", "resize"],
                defaultShortcut: Shortcut("=", modifiers: [.control, .shift, .command]),
                category: .pane,
                symbol: "equal.square",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "resizePaneLeft",
                title: String(localized: "action.resizePaneLeft", defaultValue: "Resize Pane Left", bundle: .module),
                keywords: ["resize"],
                defaultShortcut: Shortcut("h", modifiers: [.control, .shift]),
                category: .pane,
                symbol: "arrow.left.to.line",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "resizePaneRight",
                title: String(localized: "action.resizePaneRight", defaultValue: "Resize Pane Right", bundle: .module),
                keywords: ["resize"],
                defaultShortcut: Shortcut("l", modifiers: [.control, .shift]),
                category: .pane,
                symbol: "arrow.right.to.line",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "resizePaneUp",
                title: String(localized: "action.resizePaneUp", defaultValue: "Resize Pane Up", bundle: .module),
                keywords: ["resize"],
                defaultShortcut: Shortcut("k", modifiers: [.control, .shift]),
                category: .pane,
                symbol: "arrow.up.to.line.compact",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "resizePaneDown",
                title: String(localized: "action.resizePaneDown", defaultValue: "Resize Pane Down", bundle: .module),
                keywords: ["resize"],
                defaultShortcut: Shortcut("j", modifiers: [.control, .shift]),
                category: .pane,
                symbol: "arrow.down.to.line.compact",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "focusLeft",
                title: String(localized: "action.focusLeft", defaultValue: "Focus Pane Left", bundle: .module),
                keywords: ["navigate"],
                defaultShortcut: Shortcut(Shortcut.leftArrowKey, modifiers: [.option, .command]),
                category: .pane,
                symbol: "arrow.left.square",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "focusRight",
                title: String(localized: "action.focusRight", defaultValue: "Focus Pane Right", bundle: .module),
                keywords: ["navigate"],
                defaultShortcut: Shortcut(Shortcut.rightArrowKey, modifiers: [.option, .command]),
                category: .pane,
                symbol: "arrow.right.square",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "focusUp",
                title: String(localized: "action.focusUp", defaultValue: "Focus Pane Above", bundle: .module),
                keywords: ["navigate"],
                defaultShortcut: Shortcut(Shortcut.upArrowKey, modifiers: [.option, .command]),
                category: .pane,
                symbol: "arrow.up.square",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "focusDown",
                title: String(localized: "action.focusDown", defaultValue: "Focus Pane Below", bundle: .module),
                keywords: ["navigate"],
                defaultShortcut: Shortcut(Shortcut.downArrowKey, modifiers: [.option, .command]),
                category: .pane,
                symbol: "arrow.down.square",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "focusPreviousPane",
                title: String(localized: "action.focusPreviousPane", defaultValue: "Focus Previous Pane", bundle: .module),
                keywords: ["navigate"],
                category: .pane,
                symbol: "arrow.backward.square",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "focusNextPane",
                title: String(localized: "action.focusNextPane", defaultValue: "Focus Next Pane", bundle: .module),
                keywords: ["navigate"],
                category: .pane,
                symbol: "arrow.forward.square",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "triggerFlash",
                title: String(localized: "action.triggerFlash", defaultValue: "Flash Focused Pane", bundle: .module),
                keywords: ["highlight", "locate"],
                defaultShortcut: Shortcut("h", modifiers: [.command, .shift]),
                category: .pane,
                symbol: "bolt",
                surfaces: [.palette, .keyboard, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.swapWithSession",
                title: String(localized: "action.palette.swapWithSession", defaultValue: "Swap With Session…", bundle: .module),
                keywords: ["swap", "exchange"],
                category: .pane,
                symbol: "arrow.left.arrow.right",
                surfaces: [.palette, .contextMenu],
                input: .list
            ),
            ActionDescriptor(
                id: "increaseWorkspaceTerminalFontSize",
                title: String(localized: "action.increaseWorkspaceTerminalFontSize", defaultValue: "Increase Workspace Font Size", bundle: .module),
                keywords: ["zoom", "bigger"],
                defaultShortcut: Shortcut("=", modifiers: [.control, .command]),
                category: .pane,
                symbol: "textformat.size.larger",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "decreaseWorkspaceTerminalFontSize",
                title: String(localized: "action.decreaseWorkspaceTerminalFontSize", defaultValue: "Decrease Workspace Font Size", bundle: .module),
                keywords: ["zoom", "smaller"],
                defaultShortcut: Shortcut("-", modifiers: [.control, .command]),
                category: .pane,
                symbol: "textformat.size.smaller",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "resetWorkspaceTerminalFontSize",
                title: String(localized: "action.resetWorkspaceTerminalFontSize", defaultValue: "Reset Workspace Font Size", bundle: .module),
                keywords: ["zoom", "default"],
                defaultShortcut: Shortcut("0", modifiers: [.control, .command]),
                category: .pane,
                symbol: "textformat.size",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "toggleCanvasLayout",
                title: String(localized: "action.toggleCanvasLayout", defaultValue: "Toggle Canvas Layout", bundle: .module),
                keywords: ["canvas", "freeform"],
                defaultShortcut: Shortcut("c", modifiers: [.control, .command]),
                category: .pane,
                symbol: "rectangle.3.group",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "canvasOverview",
                title: String(localized: "action.canvasOverview", defaultValue: "Canvas Overview", bundle: .module),
                keywords: ["canvas", "expose"],
                defaultShortcut: Shortcut("o", modifiers: [.control, .command]),
                category: .pane,
                symbol: "square.grid.3x3",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "canvasTidy",
                title: String(localized: "action.canvasTidy", defaultValue: "Tidy Canvas", bundle: .module),
                keywords: ["canvas", "arrange"],
                defaultShortcut: Shortcut("t", modifiers: [.control, .command]),
                category: .pane,
                symbol: "square.grid.2x2.fill",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "canvasRevealFocusedPane",
                title: String(localized: "action.canvasRevealFocusedPane", defaultValue: "Reveal Focused Pane on Canvas", bundle: .module),
                keywords: ["canvas", "center"],
                defaultShortcut: Shortcut("r", modifiers: [.control, .command]),
                category: .pane,
                symbol: "scope",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "canvasZoomIn",
                title: String(localized: "action.canvasZoomIn", defaultValue: "Canvas Zoom In", bundle: .module),
                keywords: ["canvas", "zoom"],
                defaultShortcut: Shortcut("=", modifiers: [.option, .command]),
                category: .pane,
                symbol: "plus.magnifyingglass",
                surfaces: [.palette, .keyboard],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "canvasZoomOut",
                title: String(localized: "action.canvasZoomOut", defaultValue: "Canvas Zoom Out", bundle: .module),
                keywords: ["canvas", "zoom"],
                defaultShortcut: Shortcut("-", modifiers: [.option, .command]),
                category: .pane,
                symbol: "minus.magnifyingglass",
                surfaces: [.palette, .keyboard],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "canvasZoomReset",
                title: String(localized: "action.canvasZoomReset", defaultValue: "Canvas Actual Size", bundle: .module),
                keywords: ["canvas", "zoom", "reset"],
                defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .pane,
                symbol: "1.magnifyingglass",
                surfaces: [.palette, .keyboard],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "canvasAlignLeft",
                title: String(localized: "action.canvasAlignLeft", defaultValue: "Align Panes Left", bundle: .module),
                keywords: ["canvas", "align"],
                category: .pane,
                symbol: "align.horizontal.left",
                surfaces: [.palette, .keyboard],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "canvasAlignRight",
                title: String(localized: "action.canvasAlignRight", defaultValue: "Align Panes Right", bundle: .module),
                keywords: ["canvas", "align"],
                category: .pane,
                symbol: "align.horizontal.right",
                surfaces: [.palette, .keyboard],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "canvasAlignTop",
                title: String(localized: "action.canvasAlignTop", defaultValue: "Align Panes Top", bundle: .module),
                keywords: ["canvas", "align"],
                category: .pane,
                symbol: "align.vertical.top",
                surfaces: [.palette, .keyboard],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "canvasAlignBottom",
                title: String(localized: "action.canvasAlignBottom", defaultValue: "Align Panes Bottom", bundle: .module),
                keywords: ["canvas", "align"],
                category: .pane,
                symbol: "align.vertical.bottom",
                surfaces: [.palette, .keyboard],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "canvasEqualizeWidths",
                title: String(localized: "action.canvasEqualizeWidths", defaultValue: "Equalize Pane Widths", bundle: .module),
                keywords: ["canvas", "equalize"],
                category: .pane,
                symbol: "arrow.left.and.right.square",
                surfaces: [.palette, .keyboard],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "canvasEqualizeHeights",
                title: String(localized: "action.canvasEqualizeHeights", defaultValue: "Equalize Pane Heights", bundle: .module),
                keywords: ["canvas", "equalize"],
                category: .pane,
                symbol: "arrow.up.and.down.square",
                surfaces: [.palette, .keyboard],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "canvasDistributeHorizontally",
                title: String(localized: "action.canvasDistributeHorizontally", defaultValue: "Distribute Panes Horizontally", bundle: .module),
                keywords: ["canvas", "distribute"],
                category: .pane,
                symbol: "distribute.horizontal.center",
                surfaces: [.palette, .keyboard],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "canvasDistributeVertically",
                title: String(localized: "action.canvasDistributeVertically", defaultValue: "Distribute Panes Vertically", bundle: .module),
                keywords: ["canvas", "distribute"],
                category: .pane,
                symbol: "distribute.vertical.center",
                surfaces: [.palette, .keyboard],
                requires: [.canvasLayout]
            ),
            ActionDescriptor(
                id: "palette.newSimulatorPane",
                title: String(localized: "action.palette.newSimulatorPane", defaultValue: "New Simulator Pane", bundle: .module),
                keywords: ["ios", "simulator", "xcode"],
                category: .pane,
                symbol: "iphone",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "simulatorHome",
                title: String(localized: "action.simulatorHome", defaultValue: "Simulator: Home", bundle: .module),
                keywords: ["ios", "simulator"],
                defaultShortcut: Shortcut("h", modifiers: [.command, .shift]),
                category: .pane,
                symbol: "house",
                surfaces: [.keyboard],
                requires: [.simulatorFocused]
            ),
            ActionDescriptor(
                id: "simulatorRotateLeft",
                title: String(localized: "action.simulatorRotateLeft", defaultValue: "Simulator: Rotate Left", bundle: .module),
                keywords: ["ios", "simulator"],
                defaultShortcut: Shortcut(Shortcut.leftArrowKey, modifiers: [.command]),
                category: .pane,
                symbol: "rotate.left",
                surfaces: [.keyboard],
                requires: [.simulatorFocused]
            ),
            ActionDescriptor(
                id: "simulatorRotateRight",
                title: String(localized: "action.simulatorRotateRight", defaultValue: "Simulator: Rotate Right", bundle: .module),
                keywords: ["ios", "simulator"],
                defaultShortcut: Shortcut(Shortcut.rightArrowKey, modifiers: [.command]),
                category: .pane,
                symbol: "rotate.right",
                surfaces: [.keyboard],
                requires: [.simulatorFocused]
            ),
            ActionDescriptor(
                id: "simulatorToggleAppearance",
                title: String(localized: "action.simulatorToggleAppearance", defaultValue: "Simulator: Toggle Appearance", bundle: .module),
                keywords: ["ios", "simulator", "dark mode"],
                defaultShortcut: Shortcut("a", modifiers: [.command, .shift]),
                category: .pane,
                symbol: "circle.lefthalf.filled.inverse",
                surfaces: [.keyboard],
                requires: [.simulatorFocused]
            ),
            ActionDescriptor(
                id: "simulatorToggleSoftwareKeyboard",
                title: String(localized: "action.simulatorToggleSoftwareKeyboard", defaultValue: "Simulator: Toggle Software Keyboard", bundle: .module),
                keywords: ["ios", "simulator"],
                defaultShortcut: Shortcut("k", modifiers: [.command]),
                category: .pane,
                symbol: "keyboard",
                surfaces: [.keyboard],
                requires: [.simulatorFocused]
            ),
            ActionDescriptor(
                id: "palette.openFilesPane",
                title: String(localized: "action.palette.openFilesPane", defaultValue: "Open Files as Pane", bundle: .module),
                keywords: ["explorer", "pane"],
                category: .pane,
                symbol: "doc.text",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.openFindPane",
                title: String(localized: "action.palette.openFindPane", defaultValue: "Open Find as Pane", bundle: .module),
                keywords: ["search", "pane"],
                category: .pane,
                symbol: "text.magnifyingglass",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.openVaultPane",
                title: String(localized: "action.palette.openVaultPane", defaultValue: "Open Vault as Pane", bundle: .module),
                keywords: ["sessions", "pane"],
                category: .pane,
                symbol: "archivebox",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.openCloudPane",
                title: String(localized: "action.palette.openCloudPane", defaultValue: "Open Cloud as Pane", bundle: .module),
                keywords: ["machines", "pane"],
                category: .pane,
                symbol: "cloud",
                surfaces: [.palette]
            ),
        ]
    }

    private static func tabActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "newSurface",
                title: String(localized: "action.newSurface", defaultValue: "New Terminal Tab", bundle: .module),
                keywords: ["tab", "terminal", "create"],
                defaultShortcut: Shortcut("t", modifiers: [.command]),
                category: .tab,
                symbol: "plus.square",
                surfaces: [.palette, .keyboard, .contextMenu]
            ),
            ActionDescriptor(
                id: "openBrowser",
                title: String(localized: "action.openBrowser", defaultValue: "New Browser Tab", bundle: .module),
                keywords: ["tab", "web", "create"],
                defaultShortcut: Shortcut("l", modifiers: [.command, .shift]),
                category: .tab,
                symbol: "globe.badge.chevron.backward",
                surfaces: [.palette, .keyboard, .contextMenu]
            ),
            ActionDescriptor(
                id: "closeTab",
                title: String(localized: "action.closeTab", defaultValue: "Close Tab", bundle: .module),
                keywords: ["tab", "remove"],
                defaultShortcut: Shortcut("w", modifiers: [.command]),
                category: .tab,
                symbol: "xmark",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "closeOtherTabsInPane",
                title: String(localized: "action.closeOtherTabsInPane", defaultValue: "Close Other Tabs", bundle: .module),
                keywords: ["tab", "remove"],
                defaultShortcut: Shortcut("t", modifiers: [.option, .command]),
                category: .tab,
                symbol: "xmark.circle",
                surfaces: [.keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "closeTabsToLeft",
                title: String(localized: "action.closeTabsToLeft", defaultValue: "Close Tabs to the Left", bundle: .module),
                keywords: ["tab", "remove"],
                category: .tab,
                symbol: "arrow.left.to.line.compact",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "closeTabsToRight",
                title: String(localized: "action.closeTabsToRight", defaultValue: "Close Tabs to the Right", bundle: .module),
                keywords: ["tab", "remove"],
                category: .tab,
                symbol: "arrow.right.to.line.compact",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "renameTab",
                title: String(localized: "action.renameTab", defaultValue: "Rename Tab…", bundle: .module),
                keywords: ["tab", "title"],
                defaultShortcut: Shortcut("r", modifiers: [.command]),
                category: .tab,
                symbol: "pencil",
                surfaces: [.palette, .keyboard, .contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "palette.clearTabName",
                title: String(localized: "action.palette.clearTabName", defaultValue: "Clear Tab Name", bundle: .module),
                keywords: ["tab", "title", "reset"],
                category: .tab,
                symbol: "pencil.slash",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "nextSurface",
                title: String(localized: "action.nextSurface", defaultValue: "Next Tab", bundle: .module),
                keywords: ["tab", "switch"],
                defaultShortcut: Shortcut("]", modifiers: [.command, .shift]),
                category: .tab,
                symbol: "chevron.right.square",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "prevSurface",
                title: String(localized: "action.prevSurface", defaultValue: "Previous Tab", bundle: .module),
                keywords: ["tab", "switch"],
                defaultShortcut: Shortcut("[", modifiers: [.command, .shift]),
                category: .tab,
                symbol: "chevron.left.square",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "moveSurfaceLeft",
                title: String(localized: "action.moveSurfaceLeft", defaultValue: "Move Tab Left", bundle: .module),
                keywords: ["tab", "reorder"],
                defaultShortcut: Shortcut("[", modifiers: [.shift, .option, .command]),
                category: .tab,
                symbol: "arrow.left",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "moveSurfaceRight",
                title: String(localized: "action.moveSurfaceRight", defaultValue: "Move Tab Right", bundle: .module),
                keywords: ["tab", "reorder"],
                defaultShortcut: Shortcut("]", modifiers: [.shift, .option, .command]),
                category: .tab,
                symbol: "arrow.right",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "moveSurfaceToPreviousPane",
                title: String(localized: "action.moveSurfaceToPreviousPane", defaultValue: "Move Tab to Previous Pane", bundle: .module),
                keywords: ["tab", "pane"],
                defaultShortcut: Shortcut("[", modifiers: [.control, .shift, .command]),
                category: .tab,
                symbol: "arrow.backward.to.line",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "moveSurfaceToNextPane",
                title: String(localized: "action.moveSurfaceToNextPane", defaultValue: "Move Tab to Next Pane", bundle: .module),
                keywords: ["tab", "pane"],
                defaultShortcut: Shortcut("]", modifiers: [.control, .shift, .command]),
                category: .tab,
                symbol: "arrow.forward.to.line",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "moveSurfaceToPaneLeft",
                title: String(localized: "action.moveSurfaceToPaneLeft", defaultValue: "Move Tab to Pane Left", bundle: .module),
                keywords: ["tab", "pane"],
                defaultShortcut: Shortcut(Shortcut.leftArrowKey, modifiers: [.shift, .option, .command]),
                category: .tab,
                symbol: "arrow.left.square.fill",
                surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "moveSurfaceToPaneRight",
                title: String(localized: "action.moveSurfaceToPaneRight", defaultValue: "Move Tab to Pane Right", bundle: .module),
                keywords: ["tab", "pane"],
                defaultShortcut: Shortcut(Shortcut.rightArrowKey, modifiers: [.shift, .option, .command]),
                category: .tab,
                symbol: "arrow.right.square.fill",
                surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "moveSurfaceToPaneUp",
                title: String(localized: "action.moveSurfaceToPaneUp", defaultValue: "Move Tab to Pane Above", bundle: .module),
                keywords: ["tab", "pane"],
                defaultShortcut: Shortcut(Shortcut.upArrowKey, modifiers: [.shift, .option, .command]),
                category: .tab,
                symbol: "arrow.up.square.fill",
                surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "moveSurfaceToPaneDown",
                title: String(localized: "action.moveSurfaceToPaneDown", defaultValue: "Move Tab to Pane Below", bundle: .module),
                keywords: ["tab", "pane"],
                defaultShortcut: Shortcut(Shortcut.downArrowKey, modifiers: [.shift, .option, .command]),
                category: .tab,
                symbol: "arrow.down.square.fill",
                surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "selectSurfaceByNumber",
                title: String(localized: "action.selectSurfaceByNumber", defaultValue: "Select Tab 1…9", bundle: .module),
                keywords: ["tab", "switch", "index"],
                defaultShortcut: Shortcut("1", modifiers: [.control]),
                shortcutFamily: .digits,
                category: .tab,
                symbol: "number.square",
                surfaces: [.keyboard]
            ),
            ActionDescriptor(
                id: "palette.goToTab",
                title: String(localized: "action.palette.goToTab", defaultValue: "Go to Tab…", bundle: .module),
                keywords: ["tab", "switch", "switcher", "surface"],
                category: .tab,
                symbol: "rectangle.stack",
                surfaces: [.palette],
                input: .list
            ),
            ActionDescriptor(
                id: "palette.moveTabToNewWorkspace",
                title: String(localized: "action.palette.moveTabToNewWorkspace", defaultValue: "Move Tab to New Workspace", bundle: .module),
                keywords: ["tab", "detach"],
                category: .tab,
                symbol: "rectangle.portrait.and.arrow.right",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.toggleTabPin",
                title: String(localized: "action.palette.toggleTabPin", defaultValue: "Pin/Unpin Tab", bundle: .module),
                keywords: ["tab", "pin"],
                category: .tab,
                symbol: "pin.fill",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.toggleTabUnread",
                title: String(localized: "action.palette.toggleTabUnread", defaultValue: "Mark Tab as Unread", bundle: .module),
                keywords: ["tab", "unread"],
                category: .tab,
                symbol: "circle.fill",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.toggleFullWidthTab",
                title: String(localized: "action.palette.toggleFullWidthTab", defaultValue: "Toggle Full Width Tab", bundle: .module),
                keywords: ["tab", "width"],
                category: .tab,
                symbol: "arrow.left.and.right",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "duplicateTab",
                title: String(localized: "action.duplicateTab", defaultValue: "Duplicate Tab", bundle: .module),
                keywords: ["tab", "copy", "clone"],
                category: .tab,
                symbol: "plus.square.on.square",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "reloadTab",
                title: String(localized: "action.reloadTab", defaultValue: "Reload Tab", bundle: .module),
                keywords: ["tab", "refresh"],
                category: .tab,
                symbol: "arrow.clockwise",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "toggleTabAudioMute",
                title: String(localized: "action.toggleTabAudioMute", defaultValue: "Mute/Unmute Tab", bundle: .module),
                keywords: ["tab", "audio", "sound"],
                category: .tab,
                symbol: "speaker.slash",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "disconnectRemoteTab",
                title: String(localized: "action.disconnectRemoteTab", defaultValue: "Disconnect SSH Tab", bundle: .module),
                keywords: ["tab", "ssh", "remote"],
                category: .tab,
                symbol: "bolt.horizontal",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "palette.copyIdentifiers",
                title: String(localized: "action.palette.copyIdentifiers", defaultValue: "Copy Identifiers", bundle: .module),
                keywords: ["id", "ref"],
                category: .tab,
                symbol: "number.circle",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.copyPaneID",
                title: String(localized: "action.palette.copyPaneID", defaultValue: "Copy Pane ID", bundle: .module),
                keywords: ["id", "pane"],
                category: .tab,
                symbol: "doc.on.doc",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.copyPaneLink",
                title: String(localized: "action.palette.copyPaneLink", defaultValue: "Copy Pane Link", bundle: .module),
                keywords: ["url", "pane"],
                category: .tab,
                symbol: "link",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.copySurfaceID",
                title: String(localized: "action.palette.copySurfaceID", defaultValue: "Copy Tab ID", bundle: .module),
                keywords: ["id", "surface"],
                category: .tab,
                symbol: "doc.on.clipboard",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.copySurfaceLink",
                title: String(localized: "action.palette.copySurfaceLink", defaultValue: "Copy Tab Link", bundle: .module),
                keywords: ["url", "surface"],
                category: .tab,
                symbol: "link.badge.plus",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "reopenClosedBrowserPanel",
                title: String(localized: "action.reopenClosedBrowserPanel", defaultValue: "Reopen Last Closed Tab", bundle: .module),
                keywords: ["undo", "restore"],
                defaultShortcut: Shortcut("t", modifiers: [.command, .shift]),
                category: .tab,
                symbol: "arrow.uturn.backward",
                surfaces: [.palette, .keyboard, .menu]
            ),
        ]
    }

    private static func terminalActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "toggleTerminalCopyMode",
                title: String(localized: "action.toggleTerminalCopyMode", defaultValue: "Toggle Copy Mode", bundle: .module),
                keywords: ["vi", "select", "scrollback"],
                defaultShortcut: Shortcut("m", modifiers: [.command, .shift]),
                category: .terminal,
                symbol: "character.cursor.ibeam",
                surfaces: [.palette, .keyboard],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "focusTextBoxInput",
                title: String(localized: "action.focusTextBoxInput", defaultValue: "Focus TextBox", bundle: .module),
                keywords: ["input", "compose"],
                defaultShortcut: Shortcut("a", modifiers: [.command, .shift]),
                category: .terminal,
                symbol: "text.cursor",
                surfaces: [.palette, .keyboard],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.terminalToggleTextBoxInput",
                title: String(localized: "action.palette.terminalToggleTextBoxInput", defaultValue: "Toggle TextBox", bundle: .module),
                keywords: ["input", "compose"],
                category: .terminal,
                symbol: "rectangle.and.pencil.and.ellipsis",
                surfaces: [.palette],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "cycleTextBoxSubmitAction",
                title: String(localized: "action.cycleTextBoxSubmitAction", defaultValue: "Cycle TextBox Submit Action", bundle: .module),
                keywords: ["input", "compose"],
                defaultShortcut: Shortcut(Shortcut.tabKey, modifiers: [.shift]),
                category: .terminal,
                symbol: "arrow.triangle.swap",
                surfaces: [.keyboard],
                requires: [.textBoxFocused]
            ),
            ActionDescriptor(
                id: "attachTextBoxFile",
                title: String(localized: "action.attachTextBoxFile", defaultValue: "Attach File to TextBox", bundle: .module),
                keywords: ["input", "attachment"],
                defaultShortcut: Shortcut("a", modifiers: [.shift, .option, .command]),
                category: .terminal,
                symbol: "paperclip",
                surfaces: [.palette, .keyboard],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "sendCtrlFToTerminal",
                title: String(localized: "action.sendCtrlFToTerminal", defaultValue: "Send Ctrl-F to Terminal", bundle: .module),
                keywords: ["control", "key"],
                category: .terminal,
                symbol: "keyboard.badge.ellipsis",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "pasteLastScreenshot",
                title: String(localized: "action.pasteLastScreenshot", defaultValue: "Paste Last Screenshot", bundle: .module),
                keywords: ["image", "paste"],
                category: .terminal,
                symbol: "photo.on.rectangle",
                surfaces: [.palette, .keyboard],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "clearScreenKeepScrollback",
                title: String(localized: "action.clearScreenKeepScrollback", defaultValue: "Clear Screen (Keep Scrollback)", bundle: .module),
                keywords: ["clear", "reset"],
                defaultShortcut: Shortcut("k", modifiers: [.command, .shift]),
                category: .terminal,
                symbol: "clear",
                surfaces: [.palette, .keyboard],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "find",
                title: String(localized: "action.find", defaultValue: "Find…", bundle: .module),
                keywords: ["search"],
                defaultShortcut: Shortcut("f", modifiers: [.command]),
                category: .terminal,
                symbol: "magnifyingglass",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "findInDirectory",
                title: String(localized: "action.findInDirectory", defaultValue: "Find in Directory…", bundle: .module),
                keywords: ["search", "grep"],
                defaultShortcut: Shortcut("f", modifiers: [.command, .shift]),
                category: .terminal,
                symbol: "folder.badge.magnifyingglass",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "findNext",
                title: String(localized: "action.findNext", defaultValue: "Find Next", bundle: .module),
                keywords: ["search"],
                defaultShortcut: Shortcut("g", modifiers: [.command]),
                category: .terminal,
                symbol: "chevron.down.circle",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "findPrevious",
                title: String(localized: "action.findPrevious", defaultValue: "Find Previous", bundle: .module),
                keywords: ["search"],
                defaultShortcut: Shortcut("g", modifiers: [.option, .command]),
                category: .terminal,
                symbol: "chevron.up.circle",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "hideFind",
                title: String(localized: "action.hideFind", defaultValue: "Hide Find Bar", bundle: .module),
                keywords: ["search", "close"],
                defaultShortcut: Shortcut("f", modifiers: [.shift, .option, .command]),
                category: .terminal,
                symbol: "xmark.circle",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "useSelectionForFind",
                title: String(localized: "action.useSelectionForFind", defaultValue: "Use Selection for Find", bundle: .module),
                keywords: ["search", "selection"],
                defaultShortcut: Shortcut("e", modifiers: [.command]),
                category: .terminal,
                symbol: "text.magnifyingglass",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "terminalCopy",
                title: String(localized: "action.terminalCopy", defaultValue: "Copy", bundle: .module),
                keywords: ["clipboard"],
                defaultShortcut: Shortcut("c", modifiers: [.command]),
                category: .terminal,
                symbol: "doc.on.doc",
                surfaces: [.contextMenu],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "terminalPaste",
                title: String(localized: "action.terminalPaste", defaultValue: "Paste", bundle: .module),
                keywords: ["clipboard"],
                defaultShortcut: Shortcut("v", modifiers: [.command]),
                category: .terminal,
                symbol: "doc.on.clipboard",
                surfaces: [.contextMenu],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "resetTerminal",
                title: String(localized: "action.resetTerminal", defaultValue: "Reset Terminal", bundle: .module),
                keywords: ["clear", "reset"],
                category: .terminal,
                symbol: "arrow.counterclockwise",
                surfaces: [.contextMenu],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "reconnectPane",
                title: String(localized: "action.reconnectPane", defaultValue: "Reconnect Pane", bundle: .module),
                keywords: ["reconnect", "daemon"],
                category: .terminal,
                symbol: "arrow.triangle.2.circlepath.circle",
                surfaces: [.contextMenu],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "resumeCommandSet",
                title: String(localized: "action.resumeCommandSet", defaultValue: "Set Resume Command…", bundle: .module),
                keywords: ["resume", "fork"],
                category: .terminal,
                symbol: "play.circle",
                surfaces: [.contextMenu],
                requires: [.terminalFocused],
                input: .text
            ),
            ActionDescriptor(
                id: "resumeCommandEdit",
                title: String(localized: "action.resumeCommandEdit", defaultValue: "Edit Resume Command…", bundle: .module),
                keywords: ["resume", "fork"],
                category: .terminal,
                symbol: "play.square",
                surfaces: [.contextMenu],
                requires: [.terminalFocused],
                input: .text
            ),
            ActionDescriptor(
                id: "resumeCommandClear",
                title: String(localized: "action.resumeCommandClear", defaultValue: "Clear Resume Command", bundle: .module),
                keywords: ["resume", "fork"],
                category: .terminal,
                symbol: "stop.circle",
                surfaces: [.contextMenu],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.terminalOpenDirectory",
                title: String(localized: "action.palette.terminalOpenDirectory", defaultValue: "Open Current Directory in…", bundle: .module),
                keywords: ["finder", "editor", "open in"],
                category: .terminal,
                symbol: "arrow.up.forward.app",
                surfaces: [.palette],
                input: .list
            ),
        ]
    }

    private static func browserActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "browserBack",
                title: String(localized: "action.browserBack", defaultValue: "Back", bundle: .module),
                keywords: ["browser", "history"],
                defaultShortcut: Shortcut("[", modifiers: [.command]),
                category: .browser,
                symbol: "chevron.backward",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserForward",
                title: String(localized: "action.browserForward", defaultValue: "Forward", bundle: .module),
                keywords: ["browser", "history"],
                defaultShortcut: Shortcut("]", modifiers: [.command]),
                category: .browser,
                symbol: "chevron.forward",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserReload",
                title: String(localized: "action.browserReload", defaultValue: "Reload Page", bundle: .module),
                keywords: ["browser", "refresh"],
                defaultShortcut: Shortcut("r", modifiers: [.command]),
                category: .browser,
                symbol: "arrow.clockwise",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserHardReload",
                title: String(localized: "action.browserHardReload", defaultValue: "Hard Reload Page", bundle: .module),
                keywords: ["browser", "refresh", "cache"],
                defaultShortcut: Shortcut("r", modifiers: [.command, .shift]),
                category: .browser,
                symbol: "arrow.clockwise.circle",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "focusBrowserAddressBar",
                title: String(localized: "action.focusBrowserAddressBar", defaultValue: "Focus Address Bar", bundle: .module),
                keywords: ["browser", "url", "omnibox"],
                defaultShortcut: Shortcut("l", modifiers: [.command]),
                category: .browser,
                symbol: "link.circle",
                surfaces: [.palette, .keyboard],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserZoomIn",
                title: String(localized: "action.browserZoomIn", defaultValue: "Zoom In", bundle: .module),
                keywords: ["browser", "zoom"],
                defaultShortcut: Shortcut("=", modifiers: [.command]),
                category: .browser,
                symbol: "plus.magnifyingglass",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserZoomOut",
                title: String(localized: "action.browserZoomOut", defaultValue: "Zoom Out", bundle: .module),
                keywords: ["browser", "zoom"],
                defaultShortcut: Shortcut("-", modifiers: [.command]),
                category: .browser,
                symbol: "minus.magnifyingglass",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserZoomReset",
                title: String(localized: "action.browserZoomReset", defaultValue: "Actual Size", bundle: .module),
                keywords: ["browser", "zoom", "reset"],
                defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .browser,
                symbol: "1.magnifyingglass",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "markdownZoomIn",
                title: String(localized: "action.markdownZoomIn", defaultValue: "Markdown: Zoom In", bundle: .module),
                keywords: ["markdown", "zoom"],
                defaultShortcut: Shortcut("=", modifiers: [.command]),
                category: .browser,
                symbol: "plus.magnifyingglass",
                surfaces: [.palette, .keyboard],
                requires: [.markdownFocused]
            ),
            ActionDescriptor(
                id: "markdownZoomOut",
                title: String(localized: "action.markdownZoomOut", defaultValue: "Markdown: Zoom Out", bundle: .module),
                keywords: ["markdown", "zoom"],
                defaultShortcut: Shortcut("-", modifiers: [.command]),
                category: .browser,
                symbol: "minus.magnifyingglass",
                surfaces: [.palette, .keyboard],
                requires: [.markdownFocused]
            ),
            ActionDescriptor(
                id: "markdownZoomReset",
                title: String(localized: "action.markdownZoomReset", defaultValue: "Markdown: Actual Size", bundle: .module),
                keywords: ["markdown", "zoom", "reset"],
                defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .browser,
                symbol: "1.magnifyingglass",
                surfaces: [.palette, .keyboard],
                requires: [.markdownFocused]
            ),
            ActionDescriptor(
                id: "toggleBrowserDeveloperTools",
                title: String(localized: "action.toggleBrowserDeveloperTools", defaultValue: "Toggle Developer Tools", bundle: .module),
                keywords: ["browser", "devtools", "inspector"],
                defaultShortcut: Shortcut("i", modifiers: [.option, .command]),
                category: .browser,
                symbol: "hammer",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "showBrowserJavaScriptConsole",
                title: String(localized: "action.showBrowserJavaScriptConsole", defaultValue: "Show JavaScript Console", bundle: .module),
                keywords: ["browser", "devtools", "console"],
                defaultShortcut: Shortcut("c", modifiers: [.option, .command]),
                category: .browser,
                symbol: "terminal",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "toggleBrowserFocusMode",
                title: String(localized: "action.toggleBrowserFocusMode", defaultValue: "Toggle Browser Focus Mode", bundle: .module),
                keywords: ["browser", "distraction"],
                defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: [.option, .command]),
                category: .browser,
                symbol: "eye",
                surfaces: [.palette, .keyboard, .menu, .contextMenu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "toggleBrowserDesignMode",
                title: String(localized: "action.toggleBrowserDesignMode", defaultValue: "Toggle Browser Design Mode", bundle: .module),
                keywords: ["browser", "edit"],
                defaultShortcut: Shortcut("d", modifiers: [.control, .option, .command]),
                category: .browser,
                symbol: "paintbrush.pointed",
                surfaces: [.keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "toggleReactGrab",
                title: String(localized: "action.toggleReactGrab", defaultValue: "Toggle React Grab", bundle: .module),
                keywords: ["browser", "react", "inspect"],
                defaultShortcut: Shortcut("g", modifiers: [.command, .shift]),
                category: .browser,
                symbol: "hand.point.up.left",
                surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "splitBrowserRight",
                title: String(localized: "action.splitBrowserRight", defaultValue: "Split Browser Right", bundle: .module),
                keywords: ["browser", "split"],
                defaultShortcut: Shortcut("d", modifiers: [.option, .command]),
                category: .browser,
                symbol: "rectangle.righthalf.inset.filled",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "splitBrowserDown",
                title: String(localized: "action.splitBrowserDown", defaultValue: "Split Browser Down", bundle: .module),
                keywords: ["browser", "split"],
                defaultShortcut: Shortcut("d", modifiers: [.shift, .option, .command]),
                category: .browser,
                symbol: "rectangle.bottomhalf.inset.filled",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "palette.browserOpenDefault",
                title: String(localized: "action.palette.browserOpenDefault", defaultValue: "Open in Default Browser", bundle: .module),
                keywords: ["browser", "external"],
                category: .browser,
                symbol: "safari",
                surfaces: [.palette, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "palette.browserToggleOmnibar",
                title: String(localized: "action.palette.browserToggleOmnibar", defaultValue: "Toggle Omnibar", bundle: .module),
                keywords: ["browser", "address bar"],
                category: .browser,
                symbol: "rectangle.topthird.inset.filled",
                surfaces: [.palette],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "palette.browserClearHistory",
                title: String(localized: "action.palette.browserClearHistory", defaultValue: "Clear Browser History", bundle: .module),
                keywords: ["browser", "privacy"],
                category: .browser,
                symbol: "clock.badge.xmark",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "importFromBrowser",
                title: String(localized: "action.importFromBrowser", defaultValue: "Import Browser Data…", bundle: .module),
                keywords: ["browser", "bookmarks", "cookies"],
                category: .browser,
                symbol: "square.and.arrow.down.on.square",
                surfaces: [.menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.enableBrowser",
                title: String(localized: "action.palette.enableBrowser", defaultValue: "Enable cmux Browser", bundle: .module),
                keywords: ["browser", "enable"],
                category: .browser,
                symbol: "globe",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.disableBrowser",
                title: String(localized: "action.palette.disableBrowser", defaultValue: "Disable cmux Browser", bundle: .module),
                keywords: ["browser", "disable"],
                category: .browser,
                symbol: "globe.badge.chevron.backward",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "openLinkInNewTab",
                title: String(localized: "action.openLinkInNewTab", defaultValue: "Open Link in New Tab", bundle: .module),
                keywords: ["browser", "link"],
                category: .browser,
                symbol: "arrow.up.right.square",
                surfaces: [.contextMenu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "openLinkInDefaultBrowser",
                title: String(localized: "action.openLinkInDefaultBrowser", defaultValue: "Open Link in Default Browser", bundle: .module),
                keywords: ["browser", "link", "external"],
                category: .browser,
                symbol: "arrow.up.forward.app",
                surfaces: [.contextMenu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserScreenshotPage",
                title: String(localized: "action.browserScreenshotPage", defaultValue: "Screenshot Page", bundle: .module),
                keywords: ["browser", "capture"],
                category: .browser,
                symbol: "camera",
                surfaces: [.contextMenu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserScreenshotSection",
                title: String(localized: "action.browserScreenshotSection", defaultValue: "Screenshot Section", bundle: .module),
                keywords: ["browser", "capture"],
                category: .browser,
                symbol: "camera.viewfinder",
                surfaces: [.contextMenu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserTheme",
                title: String(localized: "action.browserTheme", defaultValue: "Browser Theme…", bundle: .module),
                keywords: ["browser", "appearance", "dark"],
                category: .browser,
                symbol: "circle.righthalf.filled",
                surfaces: [.contextMenu],
                requires: [.browserFocused],
                input: .list
            ),
            ActionDescriptor(
                id: "browserNewProfile",
                title: String(localized: "action.browserNewProfile", defaultValue: "New Browser Profile…", bundle: .module),
                keywords: ["browser", "profile"],
                category: .browser,
                symbol: "person.crop.circle.badge.plus",
                surfaces: [.contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "browserRenameProfile",
                title: String(localized: "action.browserRenameProfile", defaultValue: "Rename Browser Profile…", bundle: .module),
                keywords: ["browser", "profile"],
                category: .browser,
                symbol: "person.crop.circle",
                surfaces: [.contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "saveFilePreview",
                title: String(localized: "action.saveFilePreview", defaultValue: "Save File", bundle: .module),
                keywords: ["file", "editor"],
                defaultShortcut: Shortcut("s", modifiers: [.command]),
                category: .browser,
                symbol: "square.and.arrow.down",
                surfaces: [.keyboard, .menu],
                requires: [.filePreviewFocused]
            ),
            ActionDescriptor(
                id: "toggleFileEditorWordWrap",
                title: String(localized: "action.toggleFileEditorWordWrap", defaultValue: "Toggle Word Wrap", bundle: .module),
                keywords: ["file", "editor", "wrap"],
                defaultShortcut: Shortcut("z", modifiers: [.option]),
                category: .browser,
                symbol: "text.word.spacing",
                surfaces: [.keyboard],
                requires: [.filePreviewFocused]
            ),
            ActionDescriptor(
                id: "filePreviewOpenWith",
                title: String(localized: "action.filePreviewOpenWith", defaultValue: "Open File With…", bundle: .module),
                keywords: ["file", "open in"],
                category: .browser,
                symbol: "arrow.up.forward.app",
                surfaces: [.contextMenu],
                requires: [.filePreviewFocused],
                input: .list
            ),
            ActionDescriptor(
                id: "filePreviewOpenExternally",
                title: String(localized: "action.filePreviewOpenExternally", defaultValue: "Open File Externally", bundle: .module),
                keywords: ["file", "external"],
                category: .browser,
                symbol: "arrow.up.right.square",
                surfaces: [.contextMenu],
                requires: [.filePreviewFocused]
            ),
            ActionDescriptor(
                id: "filePreviewRevealInFinder",
                title: String(localized: "action.filePreviewRevealInFinder", defaultValue: "Reveal File in Finder", bundle: .module),
                keywords: ["file", "finder"],
                category: .browser,
                symbol: "folder",
                surfaces: [.contextMenu],
                requires: [.filePreviewFocused]
            ),
            ActionDescriptor(
                id: "openDiffViewer",
                title: String(localized: "action.openDiffViewer", defaultValue: "Open Diff Viewer", bundle: .module),
                keywords: ["git", "diff", "changes"],
                defaultShortcut: Shortcut("d", modifiers: [.control, .shift, .command]),
                category: .browser,
                symbol: "plusminus",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "palette.openDirectoryDiffViewer",
                title: String(localized: "action.palette.openDirectoryDiffViewer", defaultValue: "Open Directory Diff Viewer", bundle: .module),
                keywords: ["git", "diff", "changes"],
                category: .browser,
                symbol: "plus.forwardslash.minus",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "diffViewerNextLine",
                title: String(localized: "action.diffViewerNextLine", defaultValue: "Diff: Next Line", bundle: .module),
                keywords: ["diff", "vim"],
                defaultShortcut: Shortcut("j", modifiers: []),
                category: .browser,
                symbol: "arrow.down",
                surfaces: [.keyboard],
                requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerPreviousLine",
                title: String(localized: "action.diffViewerPreviousLine", defaultValue: "Diff: Previous Line", bundle: .module),
                keywords: ["diff", "vim"],
                defaultShortcut: Shortcut("k", modifiers: []),
                category: .browser,
                symbol: "arrow.up",
                surfaces: [.keyboard],
                requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerHalfPageDown",
                title: String(localized: "action.diffViewerHalfPageDown", defaultValue: "Diff: Half Page Down", bundle: .module),
                keywords: ["diff", "vim", "scroll"],
                defaultShortcut: Shortcut("d", modifiers: [.control]),
                category: .browser,
                symbol: "arrow.down.to.line",
                surfaces: [.keyboard],
                requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerHalfPageUp",
                title: String(localized: "action.diffViewerHalfPageUp", defaultValue: "Diff: Half Page Up", bundle: .module),
                keywords: ["diff", "vim", "scroll"],
                defaultShortcut: Shortcut("u", modifiers: [.control]),
                category: .browser,
                symbol: "arrow.up.to.line",
                surfaces: [.keyboard],
                requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerNextHunk",
                title: String(localized: "action.diffViewerNextHunk", defaultValue: "Diff: Next Hunk", bundle: .module),
                keywords: ["diff", "vim"],
                defaultShortcut: Shortcut("n", modifiers: [.control]),
                category: .browser,
                symbol: "chevron.down.2",
                surfaces: [.keyboard],
                requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerPreviousHunk",
                title: String(localized: "action.diffViewerPreviousHunk", defaultValue: "Diff: Previous Hunk", bundle: .module),
                keywords: ["diff", "vim"],
                defaultShortcut: Shortcut("p", modifiers: [.control]),
                category: .browser,
                symbol: "chevron.up.2",
                surfaces: [.keyboard],
                requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerGoToBottom",
                title: String(localized: "action.diffViewerGoToBottom", defaultValue: "Diff: Go to Bottom", bundle: .module),
                keywords: ["diff", "vim", "end"],
                defaultShortcut: Shortcut("g", modifiers: [.shift]),
                shortcutLabel: "G",
                category: .browser,
                symbol: "arrow.down.to.line.alt",
                surfaces: [.keyboard],
                requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerGoToTop",
                title: String(localized: "action.diffViewerGoToTop", defaultValue: "Diff: Go to Top", bundle: .module),
                keywords: ["diff", "vim", "start"],
                shortcutLabel: "g g",
                category: .browser,
                symbol: "arrow.up.to.line.alt",
                surfaces: [.keyboard],
                requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerSearch",
                title: String(localized: "action.diffViewerSearch", defaultValue: "Diff: Search", bundle: .module),
                keywords: ["diff", "vim", "find"],
                defaultShortcut: Shortcut("/", modifiers: []),
                category: .browser,
                symbol: "magnifyingglass",
                surfaces: [.keyboard],
                requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerNextFile",
                title: String(localized: "action.diffViewerNextFile", defaultValue: "Diff: Next File", bundle: .module),
                keywords: ["diff", "vim"],
                shortcutLabel: "] f",
                category: .browser,
                symbol: "doc.badge.arrow.up",
                surfaces: [.keyboard],
                requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerPreviousFile",
                title: String(localized: "action.diffViewerPreviousFile", defaultValue: "Diff: Previous File", bundle: .module),
                keywords: ["diff", "vim"],
                shortcutLabel: "[ f",
                category: .browser,
                symbol: "doc.badge.clock",
                surfaces: [.keyboard],
                requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "palette.vscodeServeWebStop",
                title: String(localized: "action.palette.vscodeServeWebStop", defaultValue: "Stop VS Code Inline Server", bundle: .module),
                keywords: ["vscode", "editor", "server"],
                category: .browser,
                symbol: "stop.fill",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.vscodeServeWebRestart",
                title: String(localized: "action.palette.vscodeServeWebRestart", defaultValue: "Restart VS Code Inline Server", bundle: .module),
                keywords: ["vscode", "editor", "server"],
                category: .browser,
                symbol: "arrow.clockwise.circle",
                surfaces: [.palette]
            ),
        ]
    }

    private static func sidebarActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "toggleSidebar",
                title: String(localized: "action.toggleSidebar", defaultValue: "Toggle Left Sidebar", bundle: .module),
                keywords: ["workspaces", "panel", "hide", "show"],
                defaultShortcut: Shortcut("b", modifiers: [.command]),
                category: .sidebar,
                symbol: "sidebar.left",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "toggleRightSidebar",
                title: String(localized: "action.toggleRightSidebar", defaultValue: "Toggle Right Sidebar", bundle: .module),
                keywords: ["files", "explorer", "panel"],
                defaultShortcut: Shortcut("b", modifiers: [.option, .command]),
                category: .sidebar,
                symbol: "sidebar.right",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "focusRightSidebar",
                title: String(localized: "action.focusRightSidebar", defaultValue: "Focus Right Sidebar", bundle: .module),
                keywords: ["files", "explorer", "panel"],
                defaultShortcut: Shortcut("e", modifiers: [.command, .shift]),
                category: .sidebar,
                symbol: "sidebar.squares.right",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "switchRightSidebarToFiles",
                title: String(localized: "action.switchRightSidebarToFiles", defaultValue: "Show Files", bundle: .module),
                keywords: ["right sidebar", "explorer"],
                defaultShortcut: Shortcut("1", modifiers: [.control]),
                category: .sidebar,
                symbol: "doc.text",
                surfaces: [.palette, .keyboard],
                requires: [.rightSidebarFocused]
            ),
            ActionDescriptor(
                id: "switchRightSidebarToFind",
                title: String(localized: "action.switchRightSidebarToFind", defaultValue: "Show Find", bundle: .module),
                keywords: ["right sidebar", "search"],
                defaultShortcut: Shortcut("2", modifiers: [.control]),
                category: .sidebar,
                symbol: "text.magnifyingglass",
                surfaces: [.palette, .keyboard],
                requires: [.rightSidebarFocused]
            ),
            ActionDescriptor(
                id: "switchRightSidebarToSessions",
                title: String(localized: "action.switchRightSidebarToSessions", defaultValue: "Show Vault", bundle: .module),
                keywords: ["right sidebar", "sessions"],
                defaultShortcut: Shortcut("3", modifiers: [.control]),
                category: .sidebar,
                symbol: "archivebox",
                surfaces: [.palette, .keyboard],
                requires: [.rightSidebarFocused]
            ),
            ActionDescriptor(
                id: "switchRightSidebarToFeed",
                title: String(localized: "action.switchRightSidebarToFeed", defaultValue: "Show Feed", bundle: .module),
                keywords: ["right sidebar", "activity"],
                defaultShortcut: Shortcut("4", modifiers: [.control]),
                category: .sidebar,
                symbol: "dot.radiowaves.left.and.right",
                surfaces: [.palette, .keyboard],
                requires: [.rightSidebarFocused]
            ),
            ActionDescriptor(
                id: "switchRightSidebarToDock",
                title: String(localized: "action.switchRightSidebarToDock", defaultValue: "Show Dock", bundle: .module),
                keywords: ["right sidebar"],
                defaultShortcut: Shortcut("5", modifiers: [.control]),
                category: .sidebar,
                symbol: "dock.rectangle",
                surfaces: [.palette, .keyboard],
                requires: [.rightSidebarFocused]
            ),
            ActionDescriptor(
                id: "switchRightSidebarToMachines",
                title: String(localized: "action.switchRightSidebarToMachines", defaultValue: "Show Cloud", bundle: .module),
                keywords: ["right sidebar", "machines"],
                defaultShortcut: Shortcut("6", modifiers: [.control]),
                category: .sidebar,
                symbol: "cloud",
                surfaces: [.palette, .keyboard],
                requires: [.rightSidebarFocused]
            ),
            ActionDescriptor(
                id: "fileExplorerOpenSelection",
                title: String(localized: "action.fileExplorerOpenSelection", defaultValue: "Open Selection", bundle: .module),
                keywords: ["file explorer"],
                defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: []),
                category: .sidebar,
                symbol: "arrow.turn.down.left",
                surfaces: [.keyboard],
                requires: [.fileExplorerFocused]
            ),
            ActionDescriptor(
                id: "fileExplorerOpenSelectionFinderAlias",
                title: String(localized: "action.fileExplorerOpenSelectionFinderAlias", defaultValue: "Open Selection (Finder Style)", bundle: .module),
                keywords: ["file explorer", "finder"],
                defaultShortcut: Shortcut(Shortcut.downArrowKey, modifiers: [.command]),
                category: .sidebar,
                symbol: "arrow.down.doc",
                surfaces: [.keyboard],
                requires: [.fileExplorerFocused]
            ),
            ActionDescriptor(
                id: "fileExplorerOpenInCmux",
                title: String(localized: "action.fileExplorerOpenInCmux", defaultValue: "Open in cmux", bundle: .module),
                keywords: ["file explorer"],
                category: .sidebar,
                symbol: "square.and.arrow.up.on.square",
                surfaces: [.contextMenu],
                requires: [.fileExplorerFocused]
            ),
            ActionDescriptor(
                id: "fileExplorerReveal",
                title: String(localized: "action.fileExplorerReveal", defaultValue: "Reveal in Finder", bundle: .module),
                keywords: ["file explorer", "finder"],
                category: .sidebar,
                symbol: "folder",
                surfaces: [.contextMenu],
                requires: [.fileExplorerFocused]
            ),
            ActionDescriptor(
                id: "fileExplorerCopyPath",
                title: String(localized: "action.fileExplorerCopyPath", defaultValue: "Copy Path", bundle: .module),
                keywords: ["file explorer", "path"],
                category: .sidebar,
                symbol: "doc.on.doc",
                surfaces: [.contextMenu],
                requires: [.fileExplorerFocused]
            ),
            ActionDescriptor(
                id: "fileExplorerCopyRelativePath",
                title: String(localized: "action.fileExplorerCopyRelativePath", defaultValue: "Copy Relative Path", bundle: .module),
                keywords: ["file explorer", "path"],
                category: .sidebar,
                symbol: "doc.on.clipboard",
                surfaces: [.contextMenu],
                requires: [.fileExplorerFocused]
            ),
            ActionDescriptor(
                id: "fileExplorerOpenWith",
                title: String(localized: "action.fileExplorerOpenWith", defaultValue: "Open With…", bundle: .module),
                keywords: ["file explorer", "open in"],
                category: .sidebar,
                symbol: "arrow.up.forward.app",
                surfaces: [.contextMenu],
                requires: [.fileExplorerFocused],
                input: .list
            ),
            ActionDescriptor(
                id: "vaultFocusSession",
                title: String(localized: "action.vaultFocusSession", defaultValue: "Focus Session", bundle: .module),
                keywords: ["vault", "session"],
                category: .sidebar,
                symbol: "scope",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "vaultOpenSession",
                title: String(localized: "action.vaultOpenSession", defaultValue: "Open Session", bundle: .module),
                keywords: ["vault", "session"],
                category: .sidebar,
                symbol: "archivebox",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "vaultResumeInNewWorkspace",
                title: String(localized: "action.vaultResumeInNewWorkspace", defaultValue: "Resume Session in New Workspace", bundle: .module),
                keywords: ["vault", "session", "resume"],
                category: .sidebar,
                symbol: "play.rectangle",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "vaultCopyResumeCommand",
                title: String(localized: "action.vaultCopyResumeCommand", defaultValue: "Copy Resume Command", bundle: .module),
                keywords: ["vault", "session", "resume"],
                category: .sidebar,
                symbol: "doc.on.doc",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "vaultOpenPullRequest",
                title: String(localized: "action.vaultOpenPullRequest", defaultValue: "Open Session Pull Request", bundle: .module),
                keywords: ["vault", "session", "github"],
                category: .sidebar,
                symbol: "arrow.triangle.pull",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "checklistEditItem",
                title: String(localized: "action.checklistEditItem", defaultValue: "Edit Checklist Item…", bundle: .module),
                keywords: ["checklist", "todo"],
                category: .sidebar,
                symbol: "pencil",
                surfaces: [.contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "checklistMarkInProgress",
                title: String(localized: "action.checklistMarkInProgress", defaultValue: "Mark Checklist Item In Progress", bundle: .module),
                keywords: ["checklist", "todo"],
                category: .sidebar,
                symbol: "circle.bottomhalf.filled",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "checklistCompleteItem",
                title: String(localized: "action.checklistCompleteItem", defaultValue: "Complete Checklist Item", bundle: .module),
                keywords: ["checklist", "todo"],
                category: .sidebar,
                symbol: "checkmark.circle.fill",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "checklistRemoveItem",
                title: String(localized: "action.checklistRemoveItem", defaultValue: "Remove Checklist Item", bundle: .module),
                keywords: ["checklist", "todo"],
                category: .sidebar,
                symbol: "minus.circle",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "checklistOpenAsPane",
                title: String(localized: "action.checklistOpenAsPane", defaultValue: "Open Checklist as Pane", bundle: .module),
                keywords: ["checklist", "todo"],
                category: .sidebar,
                symbol: "list.bullet.rectangle.portrait",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "checklistAttachImages",
                title: String(localized: "action.checklistAttachImages", defaultValue: "Attach Images to Checklist Item…", bundle: .module),
                keywords: ["checklist", "todo"],
                category: .sidebar,
                symbol: "photo.badge.plus",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "palette.toggleMatchTerminalBackground",
                title: String(localized: "action.palette.toggleMatchTerminalBackground", defaultValue: "Toggle Match Terminal Background", bundle: .module),
                keywords: ["sidebar", "theme"],
                category: .sidebar,
                symbol: "paintbrush",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.enableMinimalMode",
                title: String(localized: "action.palette.enableMinimalMode", defaultValue: "Enable Minimal Mode", bundle: .module),
                keywords: ["sidebar", "compact"],
                category: .sidebar,
                symbol: "rectangle.compress.vertical",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.disableMinimalMode",
                title: String(localized: "action.palette.disableMinimalMode", defaultValue: "Disable Minimal Mode", bundle: .module),
                keywords: ["sidebar", "compact"],
                category: .sidebar,
                symbol: "rectangle.expand.vertical",
                surfaces: [.palette]
            ),
        ]
    }

    private static func notificationsActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "showNotifications",
                title: String(localized: "action.showNotifications", defaultValue: "Show Notifications", bundle: .module),
                keywords: ["inbox", "alerts"],
                defaultShortcut: Shortcut("i", modifiers: [.command]),
                category: .notifications,
                symbol: "bell",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "jumpToUnread",
                title: String(localized: "action.jumpToUnread", defaultValue: "Jump to Latest Unread", bundle: .module),
                keywords: ["notifications", "next"],
                defaultShortcut: Shortcut("u", modifiers: [.command, .shift]),
                category: .notifications,
                symbol: "bell.badge",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "toggleUnread",
                title: String(localized: "action.toggleUnread", defaultValue: "Toggle Unread", bundle: .module),
                keywords: ["notifications", "read"],
                defaultShortcut: Shortcut("u", modifiers: [.option, .command]),
                category: .notifications,
                symbol: "circle.badge",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "markOldestUnreadAndJumpNext",
                title: String(localized: "action.markOldestUnreadAndJumpNext", defaultValue: "Mark Oldest Unread and Jump Next", bundle: .module),
                keywords: ["notifications", "triage"],
                defaultShortcut: Shortcut("u", modifiers: [.control, .command]),
                category: .notifications,
                symbol: "bell.and.waves.left.and.right",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "markAllNotificationsRead",
                title: String(localized: "action.markAllNotificationsRead", defaultValue: "Mark All Notifications as Read", bundle: .module),
                keywords: ["notifications", "read"],
                category: .notifications,
                symbol: "checkmark.circle",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "clearAllNotifications",
                title: String(localized: "action.clearAllNotifications", defaultValue: "Clear All Notifications", bundle: .module),
                keywords: ["notifications", "dismiss"],
                category: .notifications,
                symbol: "bell.slash",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "notificationOpen",
                title: String(localized: "action.notificationOpen", defaultValue: "Open Notification", bundle: .module),
                keywords: ["notifications"],
                category: .notifications,
                symbol: "bell.circle",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "notificationCopy",
                title: String(localized: "action.notificationCopy", defaultValue: "Copy Notification", bundle: .module),
                keywords: ["notifications", "clipboard"],
                category: .notifications,
                symbol: "doc.on.doc",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "notificationToggleRead",
                title: String(localized: "action.notificationToggleRead", defaultValue: "Mark Notification Read/Unread", bundle: .module),
                keywords: ["notifications"],
                category: .notifications,
                symbol: "envelope",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "notificationDismiss",
                title: String(localized: "action.notificationDismiss", defaultValue: "Dismiss Notification", bundle: .module),
                keywords: ["notifications"],
                category: .notifications,
                symbol: "xmark.circle",
                surfaces: [.contextMenu]
            ),
        ]
    }

    private static func agentsActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "palette.newAgentChat",
                title: String(localized: "action.palette.newAgentChat", defaultValue: "New Agent Chat", bundle: .module),
                keywords: ["agent", "chat", "ai"],
                category: .agents,
                symbol: "bubble.left.and.text.bubble.right",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.openTerminalChatView",
                title: String(localized: "action.palette.openTerminalChatView", defaultValue: "Open Terminal as Chat", bundle: .module),
                keywords: ["agent", "chat"],
                category: .agents,
                symbol: "text.bubble",
                surfaces: [.palette],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.launchClaudeTeams",
                title: String(localized: "action.palette.launchClaudeTeams", defaultValue: "Launch Claude Teams", bundle: .module),
                keywords: ["agent", "claude", "team"],
                category: .agents,
                symbol: "person.3",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.launchCodexTeams",
                title: String(localized: "action.palette.launchCodexTeams", defaultValue: "Launch Codex Teams", bundle: .module),
                keywords: ["agent", "codex", "team"],
                category: .agents,
                symbol: "person.3.fill",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationRight",
                title: String(localized: "action.palette.forkAgentConversationRight", defaultValue: "Fork Conversation to the Right", bundle: .module),
                keywords: ["agent", "fork"],
                category: .agents,
                symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationLeft",
                title: String(localized: "action.palette.forkAgentConversationLeft", defaultValue: "Fork Conversation to the Left", bundle: .module),
                keywords: ["agent", "fork"],
                category: .agents,
                symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationTop",
                title: String(localized: "action.palette.forkAgentConversationTop", defaultValue: "Fork Conversation Above", bundle: .module),
                keywords: ["agent", "fork"],
                category: .agents,
                symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationBottom",
                title: String(localized: "action.palette.forkAgentConversationBottom", defaultValue: "Fork Conversation Below", bundle: .module),
                keywords: ["agent", "fork"],
                category: .agents,
                symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationNewTab",
                title: String(localized: "action.palette.forkAgentConversationNewTab", defaultValue: "Fork Conversation to New Tab", bundle: .module),
                keywords: ["agent", "fork"],
                category: .agents,
                symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.forkAgentConversationNewWorkspace",
                title: String(localized: "action.palette.forkAgentConversationNewWorkspace", defaultValue: "Fork Conversation to New Workspace", bundle: .module),
                keywords: ["agent", "fork"],
                category: .agents,
                symbol: "arrow.triangle.branch",
                surfaces: [.palette, .contextMenu],
                requires: [.terminalFocused]
            ),
            ActionDescriptor(
                id: "palette.computerUse.setup",
                title: String(localized: "action.palette.computerUse.setup", defaultValue: "Computer Use Setup", bundle: .module),
                keywords: ["agent", "automation"],
                category: .agents,
                symbol: "cursorarrow.click.2",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.computerUse.accessibility",
                title: String(localized: "action.palette.computerUse.accessibility", defaultValue: "Grant Accessibility Access", bundle: .module),
                keywords: ["agent", "permissions", "tcc"],
                category: .agents,
                symbol: "accessibility",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.computerUse.screenRecording",
                title: String(localized: "action.palette.computerUse.screenRecording", defaultValue: "Grant Screen Recording Access", bundle: .module),
                keywords: ["agent", "permissions", "tcc"],
                category: .agents,
                symbol: "record.circle",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "computerUseFocus",
                title: String(localized: "action.computerUseFocus", defaultValue: "Focus Computer Use", bundle: .module),
                keywords: ["agent", "automation"],
                category: .agents,
                symbol: "cursorarrow.rays",
                surfaces: [.menu]
            ),
            ActionDescriptor(
                id: "computerUseFocusCallingTerminal",
                title: String(localized: "action.computerUseFocusCallingTerminal", defaultValue: "Focus Calling Terminal", bundle: .module),
                keywords: ["agent", "automation"],
                category: .agents,
                symbol: "terminal",
                surfaces: [.menu]
            ),
            ActionDescriptor(
                id: "computerUseStop",
                title: String(localized: "action.computerUseStop", defaultValue: "Stop Computer Use", bundle: .module),
                keywords: ["agent", "automation"],
                category: .agents,
                symbol: "stop.circle",
                surfaces: [.menu]
            ),
        ]
    }

    private static func cloudActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "newCloudWorkspace",
                title: String(localized: "action.newCloudWorkspace", defaultValue: "New Cloud Workspace", bundle: .module),
                keywords: ["vm", "remote", "create"],
                defaultShortcut: Shortcut("y", modifiers: [.command, .shift]),
                category: .cloud,
                symbol: "cloud.fill",
                surfaces: [.keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "newCloudMachine",
                title: String(localized: "action.newCloudMachine", defaultValue: "New Cloud Machine…", bundle: .module),
                keywords: ["vm", "remote", "create"],
                defaultShortcut: Shortcut("y", modifiers: [.command]),
                category: .cloud,
                symbol: "server.rack",
                surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.cloud.fork",
                title: String(localized: "action.palette.cloud.fork", defaultValue: "Fork Cloud Machine", bundle: .module),
                keywords: ["vm", "clone"],
                category: .cloud,
                symbol: "arrow.triangle.branch",
                surfaces: [.palette],
                requires: [.cloudWorkspace]
            ),
            ActionDescriptor(
                id: "palette.cloud.snapshot",
                title: String(localized: "action.palette.cloud.snapshot", defaultValue: "Snapshot Cloud Machine", bundle: .module),
                keywords: ["vm", "backup"],
                category: .cloud,
                symbol: "camera.aperture",
                surfaces: [.palette],
                requires: [.cloudWorkspace]
            ),
            ActionDescriptor(
                id: "palette.cloud.restore",
                title: String(localized: "action.palette.cloud.restore", defaultValue: "Restore Cloud Machine…", bundle: .module),
                keywords: ["vm", "snapshot"],
                category: .cloud,
                symbol: "clock.arrow.2.circlepath",
                surfaces: [.palette],
                requires: [.cloudWorkspace],
                input: .list
            ),
            ActionDescriptor(
                id: "palette.cloud.promoteTemplate",
                title: String(localized: "action.palette.cloud.promoteTemplate", defaultValue: "Promote Machine to Template", bundle: .module),
                keywords: ["vm", "template"],
                category: .cloud,
                symbol: "star.square",
                surfaces: [.palette],
                requires: [.cloudWorkspace]
            ),
            ActionDescriptor(
                id: "palette.cloud.status",
                title: String(localized: "action.palette.cloud.status", defaultValue: "Cloud Machine Status", bundle: .module),
                keywords: ["vm", "health"],
                category: .cloud,
                symbol: "waveform.path.ecg",
                surfaces: [.palette],
                requires: [.cloudWorkspace]
            ),
            ActionDescriptor(
                id: "palette.cloud.ports",
                title: String(localized: "action.palette.cloud.ports", defaultValue: "Cloud Machine Ports", bundle: .module),
                keywords: ["vm", "forward"],
                category: .cloud,
                symbol: "network",
                surfaces: [.palette],
                requires: [.cloudWorkspace]
            ),
            ActionDescriptor(
                id: "palette.cloud.tools",
                title: String(localized: "action.palette.cloud.tools", defaultValue: "Cloud Machine Tools", bundle: .module),
                keywords: ["vm"],
                category: .cloud,
                symbol: "wrench.and.screwdriver",
                surfaces: [.palette],
                requires: [.cloudWorkspace]
            ),
            ActionDescriptor(
                id: "palette.cloud.handoff",
                title: String(localized: "action.palette.cloud.handoff", defaultValue: "Hand Off Cloud Machine", bundle: .module),
                keywords: ["vm", "share"],
                category: .cloud,
                symbol: "hand.raised",
                surfaces: [.palette],
                requires: [.cloudWorkspace]
            ),
            ActionDescriptor(
                id: "cloudNewTerminal",
                title: String(localized: "action.cloudNewTerminal", defaultValue: "New Terminal on Machine", bundle: .module),
                keywords: ["vm", "cloud tree"],
                category: .cloud,
                symbol: "apple.terminal",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "cloudOpenMachine",
                title: String(localized: "action.cloudOpenMachine", defaultValue: "Open Machine", bundle: .module),
                keywords: ["vm", "cloud tree"],
                category: .cloud,
                symbol: "server.rack",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "cloudRenameMachine",
                title: String(localized: "action.cloudRenameMachine", defaultValue: "Rename Machine…", bundle: .module),
                keywords: ["vm", "cloud tree"],
                category: .cloud,
                symbol: "pencil",
                surfaces: [.contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "cloudKillMachine",
                title: String(localized: "action.cloudKillMachine", defaultValue: "Kill Machine", bundle: .module),
                keywords: ["vm", "cloud tree", "delete"],
                category: .cloud,
                symbol: "xmark.octagon",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "cloudCopyLink",
                title: String(localized: "action.cloudCopyLink", defaultValue: "Copy Machine Link", bundle: .module),
                keywords: ["vm", "cloud tree"],
                category: .cloud,
                symbol: "link",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "cloudCopyPort",
                title: String(localized: "action.cloudCopyPort", defaultValue: "Copy Machine Port", bundle: .module),
                keywords: ["vm", "cloud tree"],
                category: .cloud,
                symbol: "number",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "cloudCopyMachineID",
                title: String(localized: "action.cloudCopyMachineID", defaultValue: "Copy Machine ID", bundle: .module),
                keywords: ["vm", "cloud tree"],
                category: .cloud,
                symbol: "doc.on.doc",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "cloudResizeMachine",
                title: String(localized: "action.cloudResizeMachine", defaultValue: "Resize Machine…", bundle: .module),
                keywords: ["vm", "cloud tree", "cpu", "memory"],
                category: .cloud,
                symbol: "arrow.up.left.and.arrow.down.right",
                surfaces: [.contextMenu],
                input: .list
            ),
            ActionDescriptor(
                id: "cloudDiagnostics",
                title: String(localized: "action.cloudDiagnostics", defaultValue: "Cloud Diagnostics…", bundle: .module),
                keywords: ["vm", "debug"],
                category: .cloud,
                symbol: "stethoscope",
                surfaces: [.menu]
            ),
            ActionDescriptor(
                id: "openTeamPicker",
                title: String(localized: "action.openTeamPicker", defaultValue: "Team Picker", bundle: .module),
                keywords: ["team", "account", "switch"],
                defaultShortcut: Shortcut("t", modifiers: [.option, .shift, .command]),
                category: .cloud,
                symbol: "person.2",
                surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "palette.auth.signIn",
                title: String(localized: "action.palette.auth.signIn", defaultValue: "Sign In", bundle: .module),
                keywords: ["account", "login"],
                category: .cloud,
                symbol: "person.crop.circle.badge.checkmark",
                surfaces: [.palette],
                requires: [.signedOut]
            ),
            ActionDescriptor(
                id: "palette.auth.signOut",
                title: String(localized: "action.palette.auth.signOut", defaultValue: "Sign Out", bundle: .module),
                keywords: ["account", "logout"],
                category: .cloud,
                symbol: "person.crop.circle.badge.xmark",
                surfaces: [.palette],
                requires: [.signedIn]
            ),
            ActionDescriptor(
                id: "palette.mobileConnect",
                title: String(localized: "action.palette.mobileConnect", defaultValue: "Open Mobile Pairing", bundle: .module),
                keywords: ["ios", "phone", "pair"],
                category: .cloud,
                symbol: "iphone.radiowaves.left.and.right",
                surfaces: [.palette]
            ),
        ]
    }

    private static func settingsActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "reloadConfiguration",
                title: String(localized: "action.reloadConfiguration", defaultValue: "Reload Configuration", bundle: .module),
                keywords: ["config", "cmux.json", "ghostty"],
                defaultShortcut: Shortcut(",", modifiers: [.command, .shift]),
                category: .settings,
                symbol: "arrow.clockwise",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "palette.openCmuxSettingsFile",
                title: String(localized: "action.palette.openCmuxSettingsFile", defaultValue: "Open cmux.json", bundle: .module),
                keywords: ["config", "settings", "file"],
                category: .settings,
                symbol: "curlybraces",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "palette.openGhosttySettings",
                title: String(localized: "action.palette.openGhosttySettings", defaultValue: "Open Ghostty Config", bundle: .module),
                keywords: ["config", "settings", "file"],
                category: .settings,
                symbol: "doc.plaintext",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "palette.makeDefaultTerminal",
                title: String(localized: "action.palette.makeDefaultTerminal", defaultValue: "Make cmux the Default Terminal", bundle: .module),
                keywords: ["default", "handler"],
                category: .settings,
                symbol: "checkmark.seal",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "palette.toggleSetting",
                title: String(localized: "action.palette.toggleSetting", defaultValue: "Toggle Setting…", bundle: .module),
                keywords: ["preferences", "enable", "disable"],
                category: .settings,
                symbol: "switch.2",
                surfaces: [.palette],
                input: .list
            ),
            ActionDescriptor(
                id: "palette.shortcutKeymap",
                title: String(localized: "action.palette.shortcutKeymap", defaultValue: "Base Keymap…", bundle: .module),
                keywords: ["shortcuts", "preset", "vim"],
                category: .settings,
                symbol: "keyboard.badge.eye",
                surfaces: [.palette],
                input: .list
            ),
            ActionDescriptor(
                id: "palette.searchShortcuts",
                title: String(localized: "action.palette.searchShortcuts", defaultValue: "Search Keyboard Shortcuts…", bundle: .module),
                keywords: ["shortcuts", "keybindings", "hotkeys", "help"],
                category: .settings,
                symbol: "keyboard",
                surfaces: [.palette, .menu],
                input: .list
            ),
            ActionDescriptor(
                id: "palette.installCLI",
                title: String(localized: "action.palette.installCLI", defaultValue: "Install cmux CLI in PATH", bundle: .module),
                keywords: ["command line", "shell"],
                category: .settings,
                symbol: "terminal",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.uninstallCLI",
                title: String(localized: "action.palette.uninstallCLI", defaultValue: "Uninstall cmux CLI from PATH", bundle: .module),
                keywords: ["command line", "shell"],
                category: .settings,
                symbol: "terminal.fill",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.restartSocketListener",
                title: String(localized: "action.palette.restartSocketListener", defaultValue: "Restart CLI Listener", bundle: .module),
                keywords: ["socket", "cli"],
                category: .settings,
                symbol: "antenna.radiowaves.left.and.right",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.checkForUpdates",
                title: String(localized: "action.palette.checkForUpdates", defaultValue: "Check for Updates…", bundle: .module),
                keywords: ["update", "version", "sparkle"],
                category: .settings,
                symbol: "arrow.down.circle",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "palette.applyUpdateIfAvailable",
                title: String(localized: "action.palette.applyUpdateIfAvailable", defaultValue: "Install Available Update", bundle: .module),
                keywords: ["update", "install"],
                category: .settings,
                symbol: "arrow.down.circle.fill",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "palette.attemptUpdate",
                title: String(localized: "action.palette.attemptUpdate", defaultValue: "Attempt Update", bundle: .module),
                keywords: ["update", "retry"],
                category: .settings,
                symbol: "arrow.triangle.2.circlepath",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.switchAppChannel",
                title: String(localized: "action.palette.switchAppChannel", defaultValue: "Switch Update Channel…", bundle: .module),
                keywords: ["nightly", "beta", "stable", "channel"],
                category: .settings,
                symbol: "antenna.radiowaves.left.and.right.circle",
                surfaces: [.palette, .menu],
                input: .list
            ),
            ActionDescriptor(
                id: "palette.pro.upgrade",
                title: String(localized: "action.palette.pro.upgrade", defaultValue: "Upgrade to cmux Pro", bundle: .module),
                keywords: ["pro", "billing", "subscription"],
                category: .settings,
                symbol: "star.circle",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "palette.welcomeChecklist",
                title: String(localized: "action.palette.welcomeChecklist", defaultValue: "Welcome Checklist", bundle: .module),
                keywords: ["onboarding", "getting started"],
                category: .settings,
                symbol: "sparkles",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "sendFeedback",
                title: String(localized: "action.sendFeedback", defaultValue: "Send Feedback", bundle: .module),
                keywords: ["bug", "report", "contact"],
                category: .settings,
                symbol: "envelope",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "help.featureFlags",
                title: String(localized: "action.help.featureFlags", defaultValue: "Feature Flags", bundle: .module),
                keywords: ["experiments", "beta"],
                category: .settings,
                symbol: "flag",
                surfaces: [.menu]
            ),
            ActionDescriptor(
                id: "help.documentation",
                title: String(localized: "action.help.documentation", defaultValue: "cmux Documentation…", bundle: .module),
                keywords: ["docs", "help", "manual"],
                category: .settings,
                symbol: "book",
                surfaces: [.menu],
                input: .list
            ),
        ]
    }
}
