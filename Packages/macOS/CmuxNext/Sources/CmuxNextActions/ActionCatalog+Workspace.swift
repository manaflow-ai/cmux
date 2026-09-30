// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

extension ActionCatalog {
    static func workspaceActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "newTab", title: String(localized: "action.newTab", defaultValue: "New Workspace", bundle: .module),
                keywords: ["create", "add"], defaultShortcut: Shortcut("n", modifiers: [.command]),
                category: .workspace, symbol: "plus.rectangle.on.rectangle",
                surfaces: [.palette, .keyboard, .menu, .contextMenu],
                arguments: [CatalogArgument.nameString.optional, CatalogArgument.cwdString.optional, CatalogArgument.commandString.optional,
                            CatalogArgument.envString.optional, CatalogArgument.focusBool.optional, CatalogArgument.keepBool.optional],
                targets: [.workspace], cliName: "workspace new",
                mainMenu: .file, startsTerminal: true
            ),
            ActionDescriptor(
                id: "newBrowserWorkspace",
                title: String(localized: "action.newBrowserWorkspace", defaultValue: "New Browser Workspace", bundle: .module),
                keywords: ["web", "create"], defaultShortcut: Shortcut("n", modifiers: [.option, .command]),
                category: .workspace, symbol: "globe", surfaces: [.palette, .keyboard, .menu], targets: [.workspace],
                cliName: "workspace new-browser", mainMenu: .file
            ),
            ActionDescriptor(
                id: "openFolder",
                title: String(localized: "action.openFolder", defaultValue: "Open Folder…", bundle: .module),
                keywords: ["directory", "project"], defaultShortcut: Shortcut("o", modifiers: [.command]),
                category: .workspace, symbol: "folder", surfaces: [.palette, .keyboard, .menu], targets: [.workspace],
                cliName: "workspace open-folder", mainMenu: .file
            ),
            ActionDescriptor(
                id: "palette.openFolderInVSCodeInline",
                title: String(localized: "action.palette.openFolderInVSCodeInline", defaultValue: "Open Folder in VS Code (Inline)…", bundle: .module),
                keywords: ["editor", "code"], category: .workspace, symbol: "chevron.left.forwardslash.chevron.right",
                surfaces: [.palette, .menu], targets: [.workspace], cliName: "workspace open-folder-in-vs-code-inline",
                mainMenu: .file
            ),
            ActionDescriptor(
                id: "reopenPreviousSession",
                title: String(localized: "action.reopenPreviousSession", defaultValue: "Restore Previous App Launch", bundle: .module),
                keywords: ["session", "restore"], defaultShortcut: Shortcut("o", modifiers: [.command, .shift]),
                category: .workspace, symbol: "clock.arrow.circlepath", surfaces: [.palette, .keyboard, .menu],
                targets: [.workspace], cliName: "workspace restore-previous-app-launch", mainMenu: .file
            ),
            ActionDescriptor(
                id: "reopenClosedWorkspace",
                title: String(localized: "action.reopenClosedWorkspace", defaultValue: "Reopen Closed Workspace", bundle: .module),
                keywords: ["undo", "restore"], category: .workspace, symbol: "arrow.uturn.backward.square",
                surfaces: [.palette, .keyboard, .menu], targets: [.workspace], cliName: "workspace reopen-closed",
                mainMenu: .file
            ),
            ActionDescriptor(
                id: "nextSidebarTab",
                title: String(localized: "action.nextSidebarTab", defaultValue: "Next Workspace", bundle: .module),
                keywords: ["switch"], defaultShortcut: Shortcut("]", modifiers: [.control, .command]),
                category: .workspace, symbol: "chevron.down.square", surfaces: [.palette, .keyboard, .menu],
                targets: [.workspace], cliName: "workspace next", mainMenu: .file
            ),
            ActionDescriptor(
                id: "prevSidebarTab",
                title: String(localized: "action.prevSidebarTab", defaultValue: "Previous Workspace", bundle: .module),
                keywords: ["switch"], defaultShortcut: Shortcut("[", modifiers: [.control, .command]),
                category: .workspace, symbol: "chevron.up.square", surfaces: [.palette, .keyboard, .menu],
                targets: [.workspace], cliName: "workspace previous", mainMenu: .file
            ),
            ActionDescriptor(
                id: "nextSidebarTabInGroup",
                title: String(localized: "action.nextSidebarTabInGroup", defaultValue: "Next Workspace in Group", bundle: .module),
                keywords: ["switch"], category: .workspace, symbol: "chevron.down.circle", surfaces: [.keyboard],
                targets: [.workspace], cliName: "workspace next-in-group"
            ),
            ActionDescriptor(
                id: "prevSidebarTabInGroup",
                title: String(localized: "action.prevSidebarTabInGroup", defaultValue: "Previous Workspace in Group", bundle: .module),
                keywords: ["switch"], category: .workspace, symbol: "chevron.up.circle", surfaces: [.keyboard],
                targets: [.workspace], cliName: "workspace previous-in-group"
            ),
            ActionDescriptor(
                id: "moveWorkspaceUp",
                title: String(localized: "action.moveWorkspaceUp", defaultValue: "Move Workspace Up", bundle: .module),
                keywords: ["reorder"], defaultShortcut: Shortcut("[", modifiers: [.control, .option, .command]),
                category: .workspace, symbol: "arrow.up", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                targets: [.workspace], cliName: "workspace move-up", mainMenu: .file
            ),
            ActionDescriptor(
                id: "moveWorkspaceDown",
                title: String(localized: "action.moveWorkspaceDown", defaultValue: "Move Workspace Down", bundle: .module),
                keywords: ["reorder"], defaultShortcut: Shortcut("]", modifiers: [.control, .option, .command]),
                category: .workspace, symbol: "arrow.down", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                targets: [.workspace], cliName: "workspace move-down", mainMenu: .file
            ),
            ActionDescriptor(
                id: "palette.moveWorkspaceToTop",
                title: String(localized: "action.palette.moveWorkspaceToTop", defaultValue: "Move Workspace to Top", bundle: .module),
                keywords: ["reorder"], category: .workspace, symbol: "arrow.up.to.line",
                surfaces: [.palette, .menu, .contextMenu], targets: [.workspace], cliName: "workspace move-to-top",
                mainMenu: .file
            ),
            ActionDescriptor(
                id: "selectWorkspaceByNumber",
                title: String(localized: "action.selectWorkspaceByNumber", defaultValue: "Select Workspace 1…9", bundle: .module),
                keywords: ["switch", "index"], defaultShortcut: Shortcut("1", modifiers: [.command]),
                shortcutFamily: .digits, category: .workspace, symbol: "number", surfaces: [.keyboard, .menu],
                arguments: [CatalogArgument.indexNumber], targets: [.workspace], cliName: "workspace select-1-9",
                mainMenu: .file
            ),
            ActionDescriptor(
                id: "moveWorkspaceToWindow",
                title: String(localized: "action.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window…", bundle: .module),
                keywords: ["window"], category: .workspace, symbol: "macwindow.and.cursorarrow",
                surfaces: [.palette, .menu, .contextMenu], arguments: [CatalogArgument.windowWindow], targets: [.workspace],
                cliName: "workspace move-to-window", mainMenu: .file
            ),
            ActionDescriptor(
                id: "moveWorkspaceToNewWindow",
                title: String(localized: "action.moveWorkspaceToNewWindow", defaultValue: "Move Workspace to New Window", bundle: .module),
                keywords: ["window", "tear off", "detach"], category: .workspace, symbol: "macwindow.badge.plus",
                surfaces: [.palette, .menu, .contextMenu], targets: [.workspace],
                cliName: "workspace move-to-new-window", mainMenu: .file
            ),
            ActionDescriptor(
                id: "renameWorkspace",
                title: String(localized: "action.renameWorkspace", defaultValue: "Rename Workspace…", bundle: .module),
                keywords: ["title", "name"], defaultShortcut: Shortcut("r", modifiers: [.command, .shift]),
                category: .workspace, symbol: "pencil", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                arguments: [CatalogArgument.nameString], targets: [.workspace], cliName: "workspace rename",
                mainMenu: .file
            ),
            ActionDescriptor(
                id: "palette.clearWorkspaceName",
                title: String(localized: "action.palette.clearWorkspaceName", defaultValue: "Clear Workspace Name", bundle: .module),
                keywords: ["title", "name", "reset"], category: .workspace, symbol: "pencil.slash",
                surfaces: [.palette, .menu, .contextMenu], targets: [.workspace], cliName: "workspace clear-name",
                mainMenu: .file
            ),
            ActionDescriptor(
                id: "editWorkspaceDescription",
                title: String(localized: "action.editWorkspaceDescription", defaultValue: "Edit Workspace Description…", bundle: .module),
                keywords: ["notes", "summary"], defaultShortcut: Shortcut("e", modifiers: [.option, .command]),
                category: .workspace, symbol: "text.alignleft", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                arguments: [CatalogArgument.descriptionString], targets: [.workspace],
                cliName: "workspace edit-description", mainMenu: .file
            ),
            ActionDescriptor(
                id: "palette.clearWorkspaceDescription",
                title: String(localized: "action.palette.clearWorkspaceDescription", defaultValue: "Clear Workspace Description", bundle: .module),
                keywords: ["notes", "reset"], category: .workspace, symbol: "text.badge.xmark",
                surfaces: [.palette, .contextMenu], targets: [.workspace], cliName: "workspace clear-description"
            ),
            ActionDescriptor(
                id: "markWorkspaceDone",
                title: String(localized: "action.markWorkspaceDone", defaultValue: "Mark Workspace as Done", bundle: .module),
                keywords: ["complete", "status", "todo"], defaultShortcut: Shortcut(";", modifiers: [.command]),
                category: .workspace, symbol: "checkmark.circle", surfaces: [.palette, .keyboard, .contextMenu],
                targets: [.workspace], cliName: "workspace mark-as-done"
            ),
            ActionDescriptor(
                id: "cycleWorkspaceStatus",
                title: String(localized: "action.cycleWorkspaceStatus", defaultValue: "Cycle Workspace Status", bundle: .module),
                keywords: ["status", "todo"], defaultShortcut: Shortcut(";", modifiers: [.command, .shift]),
                category: .workspace, symbol: "circle.dashed", surfaces: [.palette, .keyboard], targets: [.workspace],
                cliName: "workspace cycle-status"
            ),
            ActionDescriptor(
                id: "palette.workspaceStatus",
                title: String(localized: "action.palette.workspaceStatus", defaultValue: "Set Workspace Status…", bundle: .module),
                keywords: ["status", "todo", "auto"], category: .workspace, symbol: "circle.lefthalf.filled",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.statusChoice], targets: [.workspace],
                cliName: "workspace set-status"
            ),
            ActionDescriptor(
                id: "palette.addWorkspaceChecklistItem",
                title: String(localized: "action.palette.addWorkspaceChecklistItem", defaultValue: "Add Checklist Item…", bundle: .module),
                keywords: ["todo", "task"], category: .workspace, symbol: "checklist",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.textString], targets: [.workspace],
                cliName: "workspace add-checklist-item"
            ),
            ActionDescriptor(
                id: "toggleChecklistItemComplete",
                title: String(localized: "action.toggleChecklistItemComplete", defaultValue: "Toggle Checklist Item Complete", bundle: .module),
                keywords: ["todo", "task"], defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: [.command]),
                category: .workspace, symbol: "checkmark.square", surfaces: [.keyboard], targets: [.workspace],
                cliName: "workspace toggle-checklist-item-complete"
            ),
            ActionDescriptor(
                id: "palette.openWorkspaceTodoPane",
                title: String(localized: "action.palette.openWorkspaceTodoPane", defaultValue: "Open Todo Pane", bundle: .module),
                keywords: ["checklist", "task"], category: .workspace, symbol: "list.bullet.rectangle",
                surfaces: [.palette], targets: [.workspace], cliName: "workspace open-todo-pane"
            ),
            ActionDescriptor(
                id: "closeWorkspace",
                title: String(localized: "action.closeWorkspace", defaultValue: "Close Workspace", bundle: .module),
                keywords: ["remove"], defaultShortcut: Shortcut("w", modifiers: [.command, .shift]),
                category: .workspace, symbol: "xmark.square", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                targets: [.workspace], cliName: "workspace close", mainMenu: .file,
                destructive: true
            ),
            ActionDescriptor(
                id: "palette.closeOtherWorkspaces",
                title: String(localized: "action.palette.closeOtherWorkspaces", defaultValue: "Close Other Workspaces", bundle: .module),
                keywords: ["remove"], category: .workspace, symbol: "xmark.square.fill",
                surfaces: [.palette, .menu, .contextMenu], targets: [.workspace], cliName: "workspace close-other",
                mainMenu: .file
            ),
            ActionDescriptor(
                id: "palette.closeWorkspacesBelow",
                title: String(localized: "action.palette.closeWorkspacesBelow", defaultValue: "Close Workspaces Below", bundle: .module),
                keywords: ["remove"], category: .workspace, symbol: "arrow.down.to.line",
                surfaces: [.palette, .menu, .contextMenu], targets: [.workspace], cliName: "workspace close-below",
                mainMenu: .file
            ),
            ActionDescriptor(
                id: "palette.closeWorkspacesAbove",
                title: String(localized: "action.palette.closeWorkspacesAbove", defaultValue: "Close Workspaces Above", bundle: .module),
                keywords: ["remove"], category: .workspace, symbol: "arrow.up.to.line",
                surfaces: [.palette, .menu, .contextMenu], targets: [.workspace], cliName: "workspace close-above",
                mainMenu: .file
            ),
            ActionDescriptor(
                id: "palette.toggleWorkspacePin",
                title: String(localized: "action.palette.toggleWorkspacePin", defaultValue: "Pin/Unpin Workspace", bundle: .module),
                keywords: ["pin", "unpin", "favorite"], category: .workspace, symbol: "pin",
                surfaces: [.palette, .menu, .contextMenu], targets: [.workspace], cliName: "workspace pin-unpin",
                mainMenu: .file
            ),
            ActionDescriptor(
                id: "palette.markWorkspaceRead",
                title: String(localized: "action.palette.markWorkspaceRead", defaultValue: "Mark Workspace as Read", bundle: .module),
                keywords: ["read", "notifications"], category: .workspace, symbol: "envelope.open",
                surfaces: [.palette, .menu, .contextMenu], targets: [.workspace], cliName: "workspace mark-as-read",
                mainMenu: .file
            ),
            ActionDescriptor(
                id: "palette.markWorkspaceUnread",
                title: String(localized: "action.palette.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread", bundle: .module),
                keywords: ["unread", "notifications"], category: .workspace, symbol: "envelope.badge",
                surfaces: [.palette, .menu, .contextMenu], targets: [.workspace], cliName: "workspace mark-as-unread",
                mainMenu: .file
            ),
            ActionDescriptor(
                id: "palette.workspaceColor",
                title: String(localized: "action.palette.workspaceColor", defaultValue: "Set Workspace Color…", bundle: .module),
                keywords: ["color", "tint"], category: .workspace, symbol: "paintpalette",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.colorChoice], targets: [.workspace],
                cliName: "workspace set-color"
            ),
            ActionDescriptor(
                id: "palette.workspaceCustomColor",
                title: String(localized: "action.palette.workspaceCustomColor", defaultValue: "Custom Workspace Color…", bundle: .module),
                keywords: ["color", "tint"], category: .workspace, symbol: "eyedropper",
                surfaces: [.palette, .contextMenu], targets: [.workspace], cliName: "workspace custom-color"
            ),
            ActionDescriptor(
                id: "palette.resetWorkspaceColor",
                title: String(localized: "action.palette.resetWorkspaceColor", defaultValue: "Reset Workspace Color", bundle: .module),
                keywords: ["color", "tint"], category: .workspace, symbol: "paintbrush",
                surfaces: [.palette, .contextMenu], targets: [.workspace], cliName: "workspace reset-color"
            ),
            ActionDescriptor(
                id: "reconnectWorkspace",
                title: String(localized: "action.reconnectWorkspace", defaultValue: "Reconnect Workspace", bundle: .module),
                keywords: ["ssh", "remote"], category: .workspace, symbol: "arrow.triangle.2.circlepath",
                surfaces: [.contextMenu], targets: [.workspace], cliName: "workspace reconnect"
            ),
            ActionDescriptor(
                id: "disconnectWorkspace",
                title: String(localized: "action.disconnectWorkspace", defaultValue: "Disconnect Workspace", bundle: .module),
                keywords: ["ssh", "remote"], category: .workspace, symbol: "bolt.horizontal.circle",
                surfaces: [.contextMenu], targets: [.workspace], cliName: "workspace disconnect"
            ),
            ActionDescriptor(
                id: "copyWorkspaceSSHError",
                title: String(localized: "action.copyWorkspaceSSHError", defaultValue: "Copy SSH Error", bundle: .module),
                keywords: ["ssh", "remote", "error"], category: .workspace, symbol: "exclamationmark.bubble",
                surfaces: [.contextMenu], targets: [.workspace], cliName: "workspace copy-ssh-error"
            ),
            ActionDescriptor(
                id: "clearWorkspaceNotifications",
                title: String(localized: "action.clearWorkspaceNotifications", defaultValue: "Clear Workspace Notifications", bundle: .module),
                keywords: ["notifications"], category: .workspace, symbol: "bell.slash", surfaces: [.contextMenu],
                targets: [.workspace], cliName: "workspace clear-notifications"
            ),
            ActionDescriptor(
                id: "revealWorkspaceInFinder",
                title: String(localized: "action.revealWorkspaceInFinder", defaultValue: "Show Workspace in Finder", bundle: .module),
                keywords: ["finder", "reveal", "directory"], category: .workspace, symbol: "folder.badge.gearshape",
                surfaces: [.contextMenu], targets: [.workspace], cliName: "workspace show-in-finder"
            ),
            ActionDescriptor(
                id: "palette.copyWorkspaceID",
                title: String(localized: "action.palette.copyWorkspaceID", defaultValue: "Copy Workspace ID", bundle: .module),
                keywords: ["identifier", "uuid"], category: .workspace, symbol: "doc.on.doc",
                surfaces: [.palette, .contextMenu], targets: [.workspace], cliName: "workspace copy-id"
            ),
            ActionDescriptor(
                id: "palette.copyWorkspaceIDAndRef",
                title: String(localized: "action.palette.copyWorkspaceIDAndRef", defaultValue: "Copy Workspace ID and Ref", bundle: .module),
                keywords: ["identifier", "ref"], category: .workspace, symbol: "doc.on.doc",
                surfaces: [.palette, .contextMenu], targets: [.workspace], cliName: "workspace copy-id-and-ref"
            ),
            ActionDescriptor(
                id: "palette.copyWorkspaceLink",
                title: String(localized: "action.palette.copyWorkspaceLink", defaultValue: "Copy Workspace Link", bundle: .module),
                keywords: ["url", "deeplink"], category: .workspace, symbol: "link", surfaces: [.palette, .contextMenu],
                targets: [.workspace], cliName: "workspace copy-link"
            ),
            ActionDescriptor(
                id: "workspaceGroup.newWorkspace",
                title: String(localized: "action.workspaceGroup.newWorkspace", defaultValue: "New Workspace in Group", bundle: .module),
                keywords: ["group", "create"], category: .workspace, symbol: "plus.square.dashed",
                surfaces: [.contextMenu], targets: [.workspaceGroup], cliName: "workspace-group new-workspace"
            ),
            ActionDescriptor(
                id: "workspaceGroup.rename",
                title: String(localized: "action.workspaceGroup.rename", defaultValue: "Rename Group…", bundle: .module),
                keywords: ["group", "title"], category: .workspace, symbol: "pencil.line", surfaces: [.contextMenu],
                arguments: [CatalogArgument.nameString], targets: [.workspaceGroup], cliName: "workspace-group rename"
            ),
            ActionDescriptor(
                id: "workspaceGroup.togglePin",
                title: String(localized: "action.workspaceGroup.togglePin", defaultValue: "Pin/Unpin Group", bundle: .module),
                keywords: ["group"], category: .workspace, symbol: "pin.circle", surfaces: [.contextMenu],
                targets: [.workspaceGroup], cliName: "workspace-group toggle-pin"
            ),
            ActionDescriptor(
                id: "workspaceGroup.markRead",
                title: String(localized: "action.workspaceGroup.markRead", defaultValue: "Mark Group as Read", bundle: .module),
                keywords: ["group", "notifications"], category: .workspace, symbol: "envelope.open.fill",
                surfaces: [.contextMenu], targets: [.workspaceGroup], cliName: "workspace-group mark-read"
            ),
            ActionDescriptor(
                id: "workspaceGroup.markUnread",
                title: String(localized: "action.workspaceGroup.markUnread", defaultValue: "Mark Group as Unread", bundle: .module),
                keywords: ["group", "notifications"], category: .workspace, symbol: "envelope.badge.fill",
                surfaces: [.contextMenu], targets: [.workspaceGroup], cliName: "workspace-group mark-unread"
            ),
            ActionDescriptor(
                id: "workspaceGroup.clearNotifications",
                title: String(localized: "action.workspaceGroup.clearNotifications", defaultValue: "Clear Group Notifications", bundle: .module),
                keywords: ["group", "notifications"], category: .workspace, symbol: "bell.slash.fill",
                surfaces: [.contextMenu], targets: [.workspaceGroup], cliName: "workspace-group clear-notifications"
            ),
            ActionDescriptor(
                id: "workspaceGroup.ungroup",
                title: String(localized: "action.workspaceGroup.ungroup", defaultValue: "Ungroup Workspaces", bundle: .module),
                keywords: ["group"], category: .workspace, symbol: "rectangle.stack.badge.minus",
                surfaces: [.contextMenu], targets: [.workspaceGroup], cliName: "workspace-group ungroup"
            ),
            ActionDescriptor(
                id: "workspaceGroup.delete",
                title: String(localized: "action.workspaceGroup.delete", defaultValue: "Delete Group", bundle: .module),
                keywords: ["group", "remove"], category: .workspace, symbol: "trash", surfaces: [.contextMenu],
                targets: [.workspaceGroup], cliName: "workspace-group delete",
                destructive: true
            ),
            ActionDescriptor(
                id: "workspaceGroup.editConfig",
                title: String(localized: "action.workspaceGroup.editConfig", defaultValue: "Edit Group Config…", bundle: .module),
                keywords: ["group", "config", "cmux.json"], category: .workspace, symbol: "slider.horizontal.3",
                surfaces: [.contextMenu], targets: [.workspaceGroup], cliName: "workspace-group edit-config"
            ),
            ActionDescriptor(
                id: "saveLayoutTemplate",
                title: String(localized: "action.saveLayoutTemplate", defaultValue: "Save Layout as Template…", bundle: .module),
                keywords: ["layout", "template"], defaultShortcut: Shortcut("s", modifiers: [.control, .command]),
                category: .workspace, symbol: "square.and.arrow.down", surfaces: [.palette, .keyboard, .contextMenu],
                arguments: [CatalogArgument.nameString], targets: [.workspace],
                cliName: "workspace save-layout-as-template"
            ),
            ActionDescriptor(
                id: "palette.layout.open",
                title: String(localized: "action.palette.layout.open", defaultValue: "New Workspace from Template…", bundle: .module),
                keywords: ["layout", "template"], category: .workspace, symbol: "square.grid.2x2",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.templateString], targets: [.workspace],
                cliName: "workspace new-from-template"
            ),
            ActionDescriptor(
                id: "manageLayouts",
                title: String(localized: "action.manageLayouts", defaultValue: "Manage Layout Templates…", bundle: .module),
                keywords: ["layout", "template", "delete", "default"], category: .workspace,
                symbol: "square.grid.3x3.square", surfaces: [.contextMenu], targets: [.workspace],
                cliName: "workspace manage-layout-templates"
            ),
            ActionDescriptor(
                id: "palette.openWorkspacePullRequests",
                title: String(localized: "action.palette.openWorkspacePullRequests", defaultValue: "Open All Workspace PR Links", bundle: .module),
                keywords: ["github", "pull request"], category: .workspace, symbol: "arrow.triangle.pull",
                surfaces: [.palette], targets: [.workspace], cliName: "workspace open-all-pr-links"
            ),
            ActionDescriptor(
                id: "palette.findWork",
                title: String(localized: "action.palette.findWork", defaultValue: "Find Work", bundle: .module),
                keywords: ["current work", "tasks"], category: .workspace, symbol: "sparkle.magnifyingglass",
                surfaces: [.palette], targets: [.workspace], cliName: "workspace find-work"
            ),
        ]
    }
}
