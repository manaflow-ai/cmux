// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum WorkspaceGroupActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "newWorkspaceGroup",
                title: String(localized: "action.newWorkspaceGroup", defaultValue: "New Workspace Group", bundle: .module),
                keywords: ["group", "create"], defaultShortcut: Shortcut("g", modifiers: [.control, .command]),
                category: .workspace, symbol: "folder.badge.plus", surfaces: [.keyboard, .menu, .contextMenu],
                arguments: [CatalogArgument.nameString.optional], targets: [.workspace],
                cliName: "workspace-group create", mainMenu: .file
            ),
            ActionDescriptor(
                id: "groupSelectedWorkspaces",
                title: String(localized: "action.groupSelectedWorkspaces", defaultValue: "Group Selected Workspaces", bundle: .module),
                keywords: ["group"], defaultShortcut: Shortcut("g", modifiers: [.command, .shift]),
                category: .workspace, symbol: "square.stack.3d.up", surfaces: [.palette, .keyboard, .contextMenu],
                targets: [.workspace], cliName: "workspace-group create-from-selection"
            ),
            ActionDescriptor(
                id: "toggleFocusedWorkspaceGroupCollapsed",
                title: String(localized: "action.toggleFocusedWorkspaceGroupCollapsed", defaultValue: "Collapse/Expand Workspace Group", bundle: .module),
                keywords: ["group", "expand", "collapse", "toggle"],
                defaultShortcut: Shortcut(".", modifiers: [.control, .command]), category: .workspace,
                symbol: "chevron.up.chevron.down", surfaces: [.palette, .keyboard], targets: [.workspaceGroup],
                cliName: "workspace-group toggle-collapse"
            ),
            ActionDescriptor(
                id: "nextWorkspaceGroup",
                title: String(localized: "action.nextWorkspaceGroup", defaultValue: "Next Workspace Group", bundle: .module),
                keywords: ["group", "switch"], defaultShortcut: Shortcut("]", modifiers: [.command, .control, .option, .shift]),
                category: .workspace, symbol: "chevron.down.circle", surfaces: [.palette, .keyboard],
                targets: [.workspace], cliName: "workspace-group next"
            ),
            ActionDescriptor(
                id: "prevWorkspaceGroup",
                title: String(localized: "action.prevWorkspaceGroup", defaultValue: "Previous Workspace Group", bundle: .module),
                keywords: ["group", "switch"], defaultShortcut: Shortcut("[", modifiers: [.command, .control, .option, .shift]),
                category: .workspace, symbol: "chevron.up.circle", surfaces: [.palette, .keyboard],
                targets: [.workspace], cliName: "workspace-group previous"
            ),
            ActionDescriptor(
                id: "moveWorkspaceToGroup",
                title: String(localized: "action.moveWorkspaceToGroup", defaultValue: "Move Workspace to Group…", bundle: .module),
                keywords: ["group"], category: .workspace, symbol: "folder.badge.questionmark",
                surfaces: [.contextMenu], arguments: [CatalogArgument.groupWorkspaceGroup], targets: [.workspace],
                cliName: "workspace-group add-workspace"
            ),
            ActionDescriptor(
                id: "removeWorkspaceFromGroup",
                title: String(localized: "action.removeWorkspaceFromGroup", defaultValue: "Remove Workspace from Group", bundle: .module),
                keywords: ["group", "ungroup"], category: .workspace, symbol: "folder.badge.minus",
                surfaces: [.contextMenu], targets: [.workspace], cliName: "workspace-group remove-workspace"
            ),
            ActionDescriptor(
                id: "workspaceGroup.setColor",
                title: String(localized: "action.workspaceGroup.setColor", defaultValue: "Set Workspace Group Color…", bundle: .module),
                keywords: ["group", "color"], category: .workspace, symbol: "paintpalette", surfaces: [.palette],
                arguments: [CatalogArgument.colorChoice], targets: [.workspaceGroup],
                cliName: "workspace-group set-color"
            ),
            ActionDescriptor(
                id: "workspaceGroup.setIcon",
                title: String(localized: "action.workspaceGroup.setIcon", defaultValue: "Set Workspace Group Icon…", bundle: .module),
                keywords: ["group", "emoji", "symbol", "badge"], category: .workspace, symbol: "face.smiling", surfaces: [.palette],
                arguments: [CatalogArgument.iconString.optional], targets: [.workspaceGroup],
                cliName: "workspace-group set-icon"
            ),
            ActionDescriptor(
                id: "workspaceGroup.clearIcon",
                title: String(localized: "action.workspaceGroup.clearIcon", defaultValue: "Remove Workspace Group Icon", bundle: .module),
                keywords: ["group", "emoji", "symbol", "reset"], category: .workspace, symbol: "xmark.circle", surfaces: [.palette],
                targets: [.workspaceGroup], cliName: "workspace-group clear-icon"
            ),
            ActionDescriptor(
                id: "workspaceGroup.copyID",
                title: String(localized: "action.workspaceGroup.copyID", defaultValue: "Copy Workspace Group ID", bundle: .module),
                keywords: ["group", "identifier", "id"], category: .workspace, symbol: "doc.on.doc", surfaces: [.palette, .contextMenu],
                targets: [.workspaceGroup],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.clipboard), contextMenus: [ActionSurfaceCatalog.p(.workspaceGroup, .identity, 140, folder: .options)])
            ),
            ActionDescriptor(
                id: "workspaceGroup.addToSection",
                title: String(localized: "action.workspaceGroup.addToSection", defaultValue: "Add Group to Section…", bundle: .module),
                keywords: ["group", "section", "sidebar", "top", "pin"], category: .workspace, symbol: "rectangle.stack",
                surfaces: [.palette, .contextMenu],
                arguments: [ActionArgument(name: "section", title: String(localized: "argument.workspaceGroup.section", defaultValue: "Section", bundle: .module),
                                           kind: .target(.sidebarSection))],
                targets: [.workspaceGroup], cliName: "workspace-group add-to-section"
            ),
            ActionDescriptor(
                id: "workspaceGroup.collapse",
                title: String(localized: "action.workspaceGroup.collapse", defaultValue: "Collapse Workspace Group", bundle: .module),
                keywords: ["group"], category: .workspace, symbol: "chevron.right", surfaces: [.palette],
                targets: [.workspaceGroup], cliName: "workspace-group collapse"
            ),
            ActionDescriptor(
                id: "workspaceGroup.expand",
                title: String(localized: "action.workspaceGroup.expand", defaultValue: "Expand Workspace Group", bundle: .module),
                keywords: ["group"], category: .workspace, symbol: "chevron.down", surfaces: [.palette],
                targets: [.workspaceGroup], cliName: "workspace-group expand"
            ),
            ActionDescriptor(
                id: "workspaceGroup.moveUp",
                title: String(localized: "action.workspaceGroup.moveUp", defaultValue: "Move Workspace Group Up", bundle: .module),
                keywords: ["group", "reorder"], category: .workspace, symbol: "arrow.up", surfaces: [.palette, .keyboard],
                targets: [.workspaceGroup], cliName: "workspace-group move-up"
            ),
            ActionDescriptor(
                id: "workspaceGroup.moveDown",
                title: String(localized: "action.workspaceGroup.moveDown", defaultValue: "Move Workspace Group Down", bundle: .module),
                keywords: ["group", "reorder"], category: .workspace, symbol: "arrow.down", surfaces: [.palette, .keyboard],
                targets: [.workspaceGroup], cliName: "workspace-group move-down"
            ),
            ActionDescriptor(
                id: "workspaceGroup.moveToTop",
                title: String(localized: "action.workspaceGroup.moveToTop", defaultValue: "Move Workspace Group to Top", table: "WorkspaceActions", bundle: .module),
                keywords: ["group", "reorder", "first", "top"], category: .workspace, symbol: "arrow.up.to.line", surfaces: [.palette, .keyboard],
                targets: [.workspaceGroup], cliName: "workspace-group move-to-top"
            ),
            ActionDescriptor(
                id: "workspaceGroup.moveToBottom",
                title: String(localized: "action.workspaceGroup.moveToBottom", defaultValue: "Move Workspace Group to Bottom", table: "WorkspaceActions", bundle: .module),
                keywords: ["group", "reorder", "last", "end", "bottom"], category: .workspace, symbol: "arrow.down.to.line", surfaces: [.palette, .keyboard],
                targets: [.workspaceGroup], cliName: "workspace-group move-to-bottom"
            ),
            // Slack's "Collapse all other sections": the other groups fold, this one opens.
            ActionDescriptor(
                id: "workspaceGroup.collapseOthers",
                title: String(localized: "action.workspaceGroup.collapseOthers", defaultValue: "Collapse Other Groups", table: "WorkspaceActions", bundle: .module),
                keywords: ["group", "collapse", "other", "others", "fold", "focus"], category: .workspace, symbol: "arrow.down.forward.and.arrow.up.backward",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspaceGroup], cliName: "workspace-group collapse-others"
            ),
            // Sorts the group's members only; the sidebar's Sort Workspaces verbs sort every container.
            ActionDescriptor(
                id: "workspaceGroup.sortByName",
                title: String(localized: "action.workspaceGroup.sortByName", defaultValue: "Sort Group by Name", table: "WorkspaceActions", bundle: .module),
                keywords: ["group", "sort", "alphabetical", "name", "order"], category: .workspace, symbol: "textformat",
                surfaces: [.palette, .contextMenu], targets: [.workspaceGroup], cliName: "workspace-group sort-by-name"
            ),
            ActionDescriptor(
                id: "workspaceGroup.sortByLastUsed",
                title: String(localized: "action.workspaceGroup.sortByLastUsed", defaultValue: "Sort Group by Last Used", table: "WorkspaceActions", bundle: .module),
                keywords: ["group", "sort", "recent", "recency", "order"], category: .workspace, symbol: "clock",
                surfaces: [.palette, .contextMenu], targets: [.workspaceGroup], cliName: "workspace-group sort-by-last-used"
            ),
            ActionDescriptor(
                id: "workspaceGroup.sortByDirectory",
                title: String(localized: "action.workspaceGroup.sortByDirectory", defaultValue: "Sort Group by Directory", table: "WorkspaceActions", bundle: .module),
                keywords: ["group", "sort", "folder", "path", "directory", "order"], category: .workspace, symbol: "folder",
                surfaces: [.palette, .contextMenu], targets: [.workspaceGroup], cliName: "workspace-group sort-by-directory"
            ),
            ActionDescriptor(
                id: "workspaceGroup.moveToWindow",
                title: String(localized: "action.workspaceGroup.moveToWindow", defaultValue: "Move Workspace Group to Window…", bundle: .module),
                keywords: ["group", "window"], category: .workspace, symbol: "macwindow.and.cursorarrow",
                surfaces: [.palette], arguments: [CatalogArgument.windowWindow], targets: [.workspaceGroup],
                cliName: "workspace-group move-to-window"
            ),
            ActionDescriptor(
                id: "workspaceGroup.closeWorkspaces",
                title: String(localized: "action.workspaceGroup.closeWorkspaces", defaultValue: "Close Workspaces in Group", bundle: .module),
                keywords: ["group", "remove"], category: .workspace, symbol: "xmark.square", surfaces: [.palette],
                targets: [.workspaceGroup], cliName: "workspace-group close-workspaces",
                destructive: true
            ),
            // Close Workspaces in Group for every other group of the window.
            ActionDescriptor(
                id: "workspaceGroup.closeOthers",
                title: String(localized: "action.workspaceGroup.closeOthers", defaultValue: "Close Other Groups", bundle: .module),
                keywords: ["group", "close", "other", "others", "remove"], category: .workspace, symbol: "xmark.circle",
                surfaces: [.palette, .contextMenu], targets: [.workspaceGroup], cliName: "workspace-group close-others",
                destructive: true
            ),
            // A new group with the same name, of a duplicate of each member.
            ActionDescriptor(
                id: "workspaceGroup.duplicate",
                title: String(localized: "action.workspaceGroup.duplicate", defaultValue: "Duplicate Workspace Group", bundle: .module),
                keywords: ["group", "duplicate", "copy", "clone"], category: .workspace, symbol: "plus.square.on.square",
                surfaces: [.palette, .contextMenu], targets: [.workspaceGroup], cliName: "workspace-group duplicate"
            ),
            ActionDescriptor(
                id: "workspaceGroup.moveToNewWindow",
                title: String(localized: "action.workspaceGroup.moveToNewWindow", defaultValue: "Move Workspace Group to New Window", bundle: .module),
                keywords: ["group", "move", "window"], category: .workspace, symbol: "macwindow.badge.plus",
                surfaces: [.palette], targets: [.workspaceGroup], cliName: "workspace-group move-to-new-window"
            ),
            ActionDescriptor(
                id: "workspaceGroup.clearColor",
                title: String(localized: "action.workspaceGroup.clearColor", defaultValue: "Remove Workspace Group Color", bundle: .module),
                keywords: ["group", "color", "clear", "reset", "none"], category: .workspace, symbol: "circle.slash",
                surfaces: [.palette, .contextMenu], targets: [.workspaceGroup], cliName: "workspace-group clear-color"
            ),
            ActionDescriptor(
                id: "workspaceGroup.color.grey",
                title: String(localized: "action.workspaceGroup.color.grey", defaultValue: "Workspace Group Color: Grey", bundle: .module),
                keywords: ["group", "color", "grey"], category: .workspace, symbol: "circle.fill", surfaces: [.palette],
                targets: [.workspaceGroup], cliName: "workspace-group color-grey"
            ),
            ActionDescriptor(
                id: "workspaceGroup.color.blue",
                title: String(localized: "action.workspaceGroup.color.blue", defaultValue: "Workspace Group Color: Blue", bundle: .module),
                keywords: ["group", "color", "blue"], category: .workspace, symbol: "circle.fill", surfaces: [.palette],
                targets: [.workspaceGroup], cliName: "workspace-group color-blue"
            ),
            ActionDescriptor(
                id: "workspaceGroup.color.red",
                title: String(localized: "action.workspaceGroup.color.red", defaultValue: "Workspace Group Color: Red", bundle: .module),
                keywords: ["group", "color", "red"], category: .workspace, symbol: "circle.fill", surfaces: [.palette],
                targets: [.workspaceGroup], cliName: "workspace-group color-red"
            ),
            ActionDescriptor(
                id: "workspaceGroup.color.yellow",
                title: String(localized: "action.workspaceGroup.color.yellow", defaultValue: "Workspace Group Color: Yellow", bundle: .module),
                keywords: ["group", "color", "yellow"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette], targets: [.workspaceGroup], cliName: "workspace-group color-yellow"
            ),
            ActionDescriptor(
                id: "workspaceGroup.color.green",
                title: String(localized: "action.workspaceGroup.color.green", defaultValue: "Workspace Group Color: Green", bundle: .module),
                keywords: ["group", "color", "green"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette], targets: [.workspaceGroup], cliName: "workspace-group color-green"
            ),
            ActionDescriptor(
                id: "workspaceGroup.color.pink",
                title: String(localized: "action.workspaceGroup.color.pink", defaultValue: "Workspace Group Color: Pink", bundle: .module),
                keywords: ["group", "color", "pink"], category: .workspace, symbol: "circle.fill", surfaces: [.palette],
                targets: [.workspaceGroup], cliName: "workspace-group color-pink"
            ),
            ActionDescriptor(
                id: "workspaceGroup.color.purple",
                title: String(localized: "action.workspaceGroup.color.purple", defaultValue: "Workspace Group Color: Purple", bundle: .module),
                keywords: ["group", "color", "purple"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette], targets: [.workspaceGroup], cliName: "workspace-group color-purple"
            ),
            ActionDescriptor(
                id: "workspaceGroup.color.cyan",
                title: String(localized: "action.workspaceGroup.color.cyan", defaultValue: "Workspace Group Color: Cyan", bundle: .module),
                keywords: ["group", "color", "cyan"], category: .workspace, symbol: "circle.fill", surfaces: [.palette],
                targets: [.workspaceGroup], cliName: "workspace-group color-cyan"
            ),
            ActionDescriptor(
                id: "workspaceGroup.color.orange",
                title: String(localized: "action.workspaceGroup.color.orange", defaultValue: "Workspace Group Color: Orange", bundle: .module),
                keywords: ["group", "color", "orange"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette], targets: [.workspaceGroup], cliName: "workspace-group color-orange"
            ),
        ]
    }
}
