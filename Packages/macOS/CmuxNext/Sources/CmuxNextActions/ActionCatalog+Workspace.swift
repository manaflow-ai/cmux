// Catalog rows for one inventory domain. Titles live in Localizable.xcstrings (en, ja).

extension ActionCatalog {
    static func workspaceActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "newTab", title: String(localized: "action.newTab", defaultValue: "New Workspace", bundle: .module),
                keywords: ["create", "add"], defaultShortcut: Shortcut("n", modifiers: [.command]),
                category: .workspace, symbol: "plus.rectangle.on.rectangle",
                surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "newBrowserWorkspace",
                title: String(localized: "action.newBrowserWorkspace", defaultValue: "New Browser Workspace", bundle: .module),
                keywords: ["web", "create"], defaultShortcut: Shortcut("n", modifiers: [.option, .command]),
                category: .workspace, symbol: "globe", surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "openFolder",
                title: String(localized: "action.openFolder", defaultValue: "Open Folder…", bundle: .module),
                keywords: ["directory", "project"], defaultShortcut: Shortcut("o", modifiers: [.command]),
                category: .workspace, symbol: "folder", surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "palette.openFolderInVSCodeInline",
                title: String(localized: "action.palette.openFolderInVSCodeInline", defaultValue: "Open Folder in VS Code (Inline)…", bundle: .module),
                keywords: ["editor", "code"], category: .workspace, symbol: "chevron.left.forwardslash.chevron.right",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "reopenPreviousSession",
                title: String(localized: "action.reopenPreviousSession", defaultValue: "Restore Previous App Launch", bundle: .module),
                keywords: ["session", "restore"], defaultShortcut: Shortcut("o", modifiers: [.command, .shift]),
                category: .workspace, symbol: "clock.arrow.circlepath", surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "reopenClosedWorkspace",
                title: String(localized: "action.reopenClosedWorkspace", defaultValue: "Reopen Closed Workspace", bundle: .module),
                keywords: ["undo", "restore"], category: .workspace, symbol: "arrow.uturn.backward.square",
                surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "nextSidebarTab",
                title: String(localized: "action.nextSidebarTab", defaultValue: "Next Workspace", bundle: .module),
                keywords: ["switch"], defaultShortcut: Shortcut("]", modifiers: [.control, .command]),
                category: .workspace, symbol: "chevron.down.square", surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "prevSidebarTab",
                title: String(localized: "action.prevSidebarTab", defaultValue: "Previous Workspace", bundle: .module),
                keywords: ["switch"], defaultShortcut: Shortcut("[", modifiers: [.control, .command]),
                category: .workspace, symbol: "chevron.up.square", surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "nextSidebarTabInGroup",
                title: String(localized: "action.nextSidebarTabInGroup", defaultValue: "Next Workspace in Group", bundle: .module),
                keywords: ["switch"], category: .workspace, symbol: "chevron.down.circle", surfaces: [.keyboard]
            ),
            ActionDescriptor(
                id: "prevSidebarTabInGroup",
                title: String(localized: "action.prevSidebarTabInGroup", defaultValue: "Previous Workspace in Group", bundle: .module),
                keywords: ["switch"], category: .workspace, symbol: "chevron.up.circle", surfaces: [.keyboard]
            ),
            ActionDescriptor(
                id: "moveWorkspaceUp",
                title: String(localized: "action.moveWorkspaceUp", defaultValue: "Move Workspace Up", bundle: .module),
                keywords: ["reorder"], defaultShortcut: Shortcut("[", modifiers: [.control, .option, .command]),
                category: .workspace, symbol: "arrow.up", surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "moveWorkspaceDown",
                title: String(localized: "action.moveWorkspaceDown", defaultValue: "Move Workspace Down", bundle: .module),
                keywords: ["reorder"], defaultShortcut: Shortcut("]", modifiers: [.control, .option, .command]),
                category: .workspace, symbol: "arrow.down", surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.moveWorkspaceToTop",
                title: String(localized: "action.palette.moveWorkspaceToTop", defaultValue: "Move Workspace to Top", bundle: .module),
                keywords: ["reorder"], category: .workspace, symbol: "arrow.up.to.line",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "selectWorkspaceByNumber",
                title: String(localized: "action.selectWorkspaceByNumber", defaultValue: "Select Workspace 1…9", bundle: .module),
                keywords: ["switch", "index"], defaultShortcut: Shortcut("1", modifiers: [.command]),
                shortcutFamily: .digits, category: .workspace, symbol: "number", surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "moveWorkspaceToWindow",
                title: String(localized: "action.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window…", bundle: .module),
                keywords: ["window"], category: .workspace, symbol: "macwindow.and.cursorarrow",
                surfaces: [.menu, .contextMenu], input: .list
            ),
            ActionDescriptor(
                id: "renameWorkspace",
                title: String(localized: "action.renameWorkspace", defaultValue: "Rename Workspace…", bundle: .module),
                keywords: ["title", "name"], defaultShortcut: Shortcut("r", modifiers: [.command, .shift]),
                category: .workspace, symbol: "pencil", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "palette.clearWorkspaceName",
                title: String(localized: "action.palette.clearWorkspaceName", defaultValue: "Clear Workspace Name", bundle: .module),
                keywords: ["title", "name", "reset"], category: .workspace, symbol: "pencil.slash",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "editWorkspaceDescription",
                title: String(localized: "action.editWorkspaceDescription", defaultValue: "Edit Workspace Description…", bundle: .module),
                keywords: ["notes", "summary"], defaultShortcut: Shortcut("e", modifiers: [.option, .command]),
                category: .workspace, symbol: "text.alignleft", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "palette.clearWorkspaceDescription",
                title: String(localized: "action.palette.clearWorkspaceDescription", defaultValue: "Clear Workspace Description", bundle: .module),
                keywords: ["notes", "reset"], category: .workspace, symbol: "text.badge.xmark",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "markWorkspaceDone",
                title: String(localized: "action.markWorkspaceDone", defaultValue: "Mark Workspace as Done", bundle: .module),
                keywords: ["complete", "status", "todo"], defaultShortcut: Shortcut(";", modifiers: [.command]),
                category: .workspace, symbol: "checkmark.circle", surfaces: [.palette, .keyboard, .contextMenu]
            ),
            ActionDescriptor(
                id: "cycleWorkspaceStatus",
                title: String(localized: "action.cycleWorkspaceStatus", defaultValue: "Cycle Workspace Status", bundle: .module),
                keywords: ["status", "todo"], defaultShortcut: Shortcut(";", modifiers: [.command, .shift]),
                category: .workspace, symbol: "circle.dashed", surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "palette.workspaceStatus",
                title: String(localized: "action.palette.workspaceStatus", defaultValue: "Set Workspace Status…", bundle: .module),
                keywords: ["status", "todo", "auto"], category: .workspace, symbol: "circle.lefthalf.filled",
                surfaces: [.palette, .contextMenu], input: .list
            ),
            ActionDescriptor(
                id: "palette.addWorkspaceChecklistItem",
                title: String(localized: "action.palette.addWorkspaceChecklistItem", defaultValue: "Add Checklist Item…", bundle: .module),
                keywords: ["todo", "task"], category: .workspace, symbol: "checklist",
                surfaces: [.palette, .contextMenu], input: .text
            ),
            ActionDescriptor(
                id: "toggleChecklistItemComplete",
                title: String(localized: "action.toggleChecklistItemComplete", defaultValue: "Toggle Checklist Item Complete", bundle: .module),
                keywords: ["todo", "task"], defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: [.command]),
                category: .workspace, symbol: "checkmark.square", surfaces: [.keyboard]
            ),
            ActionDescriptor(
                id: "palette.openWorkspaceTodoPane",
                title: String(localized: "action.palette.openWorkspaceTodoPane", defaultValue: "Open Todo Pane", bundle: .module),
                keywords: ["checklist", "task"], category: .workspace, symbol: "list.bullet.rectangle",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "closeWorkspace",
                title: String(localized: "action.closeWorkspace", defaultValue: "Close Workspace", bundle: .module),
                keywords: ["remove"], defaultShortcut: Shortcut("w", modifiers: [.command, .shift]),
                category: .workspace, symbol: "xmark.square", surfaces: [.palette, .keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.closeOtherWorkspaces",
                title: String(localized: "action.palette.closeOtherWorkspaces", defaultValue: "Close Other Workspaces", bundle: .module),
                keywords: ["remove"], category: .workspace, symbol: "xmark.square.fill",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.closeWorkspacesBelow",
                title: String(localized: "action.palette.closeWorkspacesBelow", defaultValue: "Close Workspaces Below", bundle: .module),
                keywords: ["remove"], category: .workspace, symbol: "arrow.down.to.line",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.closeWorkspacesAbove",
                title: String(localized: "action.palette.closeWorkspacesAbove", defaultValue: "Close Workspaces Above", bundle: .module),
                keywords: ["remove"], category: .workspace, symbol: "arrow.up.to.line",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.toggleWorkspacePin",
                title: String(localized: "action.palette.toggleWorkspacePin", defaultValue: "Pin/Unpin Workspace", bundle: .module),
                keywords: ["pin", "unpin", "favorite"], category: .workspace, symbol: "pin",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.markWorkspaceRead",
                title: String(localized: "action.palette.markWorkspaceRead", defaultValue: "Mark Workspace as Read", bundle: .module),
                keywords: ["read", "notifications"], category: .workspace, symbol: "envelope.open",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.markWorkspaceUnread",
                title: String(localized: "action.palette.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread", bundle: .module),
                keywords: ["unread", "notifications"], category: .workspace, symbol: "envelope.badge",
                surfaces: [.palette, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.workspaceColor",
                title: String(localized: "action.palette.workspaceColor", defaultValue: "Set Workspace Color…", bundle: .module),
                keywords: ["color", "tint"], category: .workspace, symbol: "paintpalette",
                surfaces: [.palette, .contextMenu], input: .list
            ),
            ActionDescriptor(
                id: "palette.workspaceCustomColor",
                title: String(localized: "action.palette.workspaceCustomColor", defaultValue: "Custom Workspace Color…", bundle: .module),
                keywords: ["color", "tint"], category: .workspace, symbol: "eyedropper",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.resetWorkspaceColor",
                title: String(localized: "action.palette.resetWorkspaceColor", defaultValue: "Reset Workspace Color", bundle: .module),
                keywords: ["color", "tint"], category: .workspace, symbol: "paintbrush",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "reconnectWorkspace",
                title: String(localized: "action.reconnectWorkspace", defaultValue: "Reconnect Workspace", bundle: .module),
                keywords: ["ssh", "remote"], category: .workspace, symbol: "arrow.triangle.2.circlepath",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "disconnectWorkspace",
                title: String(localized: "action.disconnectWorkspace", defaultValue: "Disconnect Workspace", bundle: .module),
                keywords: ["ssh", "remote"], category: .workspace, symbol: "bolt.horizontal.circle",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "copyWorkspaceSSHError",
                title: String(localized: "action.copyWorkspaceSSHError", defaultValue: "Copy SSH Error", bundle: .module),
                keywords: ["ssh", "remote", "error"], category: .workspace, symbol: "exclamationmark.bubble",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "clearWorkspaceNotifications",
                title: String(localized: "action.clearWorkspaceNotifications", defaultValue: "Clear Workspace Notifications", bundle: .module),
                keywords: ["notifications"], category: .workspace, symbol: "bell.slash", surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "revealWorkspaceInFinder",
                title: String(localized: "action.revealWorkspaceInFinder", defaultValue: "Show Workspace in Finder", bundle: .module),
                keywords: ["finder", "reveal", "directory"], category: .workspace, symbol: "folder.badge.gearshape",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "palette.copyWorkspaceID",
                title: String(localized: "action.palette.copyWorkspaceID", defaultValue: "Copy Workspace ID", bundle: .module),
                keywords: ["identifier", "uuid"], category: .workspace, symbol: "doc.on.doc",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.copyWorkspaceIDAndRef",
                title: String(localized: "action.palette.copyWorkspaceIDAndRef", defaultValue: "Copy Workspace ID and Ref", bundle: .module),
                keywords: ["identifier", "ref"], category: .workspace, symbol: "doc.on.doc",
                surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.copyWorkspaceLink",
                title: String(localized: "action.palette.copyWorkspaceLink", defaultValue: "Copy Workspace Link", bundle: .module),
                keywords: ["url", "deeplink"], category: .workspace, symbol: "link", surfaces: [.palette, .contextMenu]
            ),
            ActionDescriptor(
                id: "newWorkspaceGroup",
                title: String(localized: "action.newWorkspaceGroup", defaultValue: "New Workspace Group", bundle: .module),
                keywords: ["group", "create"], defaultShortcut: Shortcut("g", modifiers: [.control, .command]),
                category: .workspace, symbol: "folder.badge.plus", surfaces: [.keyboard, .menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "groupSelectedWorkspaces",
                title: String(localized: "action.groupSelectedWorkspaces", defaultValue: "Group Selected Workspaces", bundle: .module),
                keywords: ["group"], defaultShortcut: Shortcut("g", modifiers: [.command, .shift]),
                category: .workspace, symbol: "square.stack.3d.up", surfaces: [.palette, .keyboard, .contextMenu]
            ),
            ActionDescriptor(
                id: "toggleFocusedWorkspaceGroupCollapsed",
                title: String(localized: "action.toggleFocusedWorkspaceGroupCollapsed", defaultValue: "Toggle Group Collapse", bundle: .module),
                keywords: ["group", "expand", "collapse"],
                defaultShortcut: Shortcut(".", modifiers: [.control, .command]), category: .workspace,
                symbol: "chevron.up.chevron.down", surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "moveWorkspaceToGroup",
                title: String(localized: "action.moveWorkspaceToGroup", defaultValue: "Move Workspace to Group…", bundle: .module),
                keywords: ["group"], category: .workspace, symbol: "folder.badge.questionmark",
                surfaces: [.contextMenu], input: .list
            ),
            ActionDescriptor(
                id: "removeWorkspaceFromGroup",
                title: String(localized: "action.removeWorkspaceFromGroup", defaultValue: "Remove Workspace from Group", bundle: .module),
                keywords: ["group", "ungroup"], category: .workspace, symbol: "folder.badge.minus",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.newWorkspace",
                title: String(localized: "action.group.newWorkspace", defaultValue: "New Workspace in Group", bundle: .module),
                keywords: ["group", "create"], category: .workspace, symbol: "plus.square.dashed",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.rename",
                title: String(localized: "action.group.rename", defaultValue: "Rename Group…", bundle: .module),
                keywords: ["group", "title"], category: .workspace, symbol: "pencil.line", surfaces: [.contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "group.togglePin",
                title: String(localized: "action.group.togglePin", defaultValue: "Pin/Unpin Group", bundle: .module),
                keywords: ["group"], category: .workspace, symbol: "pin.circle", surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.markRead",
                title: String(localized: "action.group.markRead", defaultValue: "Mark Group as Read", bundle: .module),
                keywords: ["group", "notifications"], category: .workspace, symbol: "envelope.open.fill",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.markUnread",
                title: String(localized: "action.group.markUnread", defaultValue: "Mark Group as Unread", bundle: .module),
                keywords: ["group", "notifications"], category: .workspace, symbol: "envelope.badge.fill",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.clearNotifications",
                title: String(localized: "action.group.clearNotifications", defaultValue: "Clear Group Notifications", bundle: .module),
                keywords: ["group", "notifications"], category: .workspace, symbol: "bell.slash.fill",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.ungroup",
                title: String(localized: "action.group.ungroup", defaultValue: "Ungroup Workspaces", bundle: .module),
                keywords: ["group"], category: .workspace, symbol: "rectangle.stack.badge.minus",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.delete",
                title: String(localized: "action.group.delete", defaultValue: "Delete Group", bundle: .module),
                keywords: ["group", "remove"], category: .workspace, symbol: "trash", surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "group.editConfig",
                title: String(localized: "action.group.editConfig", defaultValue: "Edit Group Config…", bundle: .module),
                keywords: ["group", "config", "cmux.json"], category: .workspace, symbol: "slider.horizontal.3",
                surfaces: [.contextMenu]
            ),
            ActionDescriptor(
                id: "saveLayoutTemplate",
                title: String(localized: "action.saveLayoutTemplate", defaultValue: "Save Layout as Template…", bundle: .module),
                keywords: ["layout", "template"], defaultShortcut: Shortcut("s", modifiers: [.control, .command]),
                category: .workspace, symbol: "square.and.arrow.down", surfaces: [.palette, .keyboard, .contextMenu],
                input: .text
            ),
            ActionDescriptor(
                id: "palette.layout.open",
                title: String(localized: "action.palette.layout.open", defaultValue: "New Workspace from Template…", bundle: .module),
                keywords: ["layout", "template"], category: .workspace, symbol: "square.grid.2x2",
                surfaces: [.palette, .contextMenu], input: .list
            ),
            ActionDescriptor(
                id: "manageLayouts",
                title: String(localized: "action.manageLayouts", defaultValue: "Manage Layout Templates…", bundle: .module),
                keywords: ["layout", "template", "delete", "default"], category: .workspace,
                symbol: "square.grid.3x3.square", surfaces: [.contextMenu], input: .list
            ),
            ActionDescriptor(
                id: "palette.openWorkspacePullRequests",
                title: String(localized: "action.palette.openWorkspacePullRequests", defaultValue: "Open All Workspace PR Links", bundle: .module),
                keywords: ["github", "pull request"], category: .workspace, symbol: "arrow.triangle.pull",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.findWork",
                title: String(localized: "action.palette.findWork", defaultValue: "Find Work", bundle: .module),
                keywords: ["current work", "tasks"], category: .workspace, symbol: "sparkle.magnifyingglass",
                surfaces: [.palette]
            ),
        ]
    }
}
