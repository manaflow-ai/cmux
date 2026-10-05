// New workspace verbs (plans/cmux-next/REWRITE.md round 3, "Workspace
// verbs"): placement, duplicate, icon, order, sort, navigation and merge.
// Titles live in WorkspaceActions.xcstrings.

nonisolated enum WorkspaceVerbActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "workspace.newAbove",
                title: String(localized: "action.workspace.newAbove", defaultValue: "New Workspace Above", table: "WorkspaceActions", bundle: .module),
                keywords: ["create", "insert", "before"], category: .workspace, symbol: "arrow.up.square",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace new-above", startsTerminal: true
            ),
            ActionDescriptor(
                id: "workspace.newBelow",
                title: String(localized: "action.workspace.newBelow", defaultValue: "New Workspace Below", table: "WorkspaceActions", bundle: .module),
                keywords: ["create", "insert", "after"], category: .workspace, symbol: "arrow.down.square",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace new-below", startsTerminal: true
            ),
            ActionDescriptor(
                id: "workspace.newAtTop",
                title: String(localized: "action.workspace.newAtTop", defaultValue: "New Workspace at Top", table: "WorkspaceActions", bundle: .module),
                keywords: ["create", "first"], category: .workspace, symbol: "arrow.up.to.line",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace new-at-top", startsTerminal: true
            ),
            ActionDescriptor(
                id: "workspace.newAtBottom",
                title: String(localized: "action.workspace.newAtBottom", defaultValue: "New Workspace at Bottom", table: "WorkspaceActions", bundle: .module),
                keywords: ["create", "last", "end"], category: .workspace, symbol: "arrow.down.to.line",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace new-at-bottom", startsTerminal: true
            ),
            ActionDescriptor(
                id: "workspace.newInGroup",
                title: String(localized: "action.workspace.newInGroup", defaultValue: "New Workspace in This Group", table: "WorkspaceActions", bundle: .module),
                keywords: ["create", "group", "section"], category: .workspace, symbol: "folder.badge.plus",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace new-in-group", startsTerminal: true
            ),
            ActionDescriptor(
                id: "workspace.newInNewGroup",
                title: String(localized: "action.workspace.newInNewGroup", defaultValue: "New Workspace in New Group", table: "WorkspaceActions", bundle: .module),
                keywords: ["create", "group", "section"], category: .workspace, symbol: "rectangle.stack.badge.plus",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [CatalogArgument.nameString.optional], targets: [.workspace], cliName: "workspace new-in-new-group", startsTerminal: true
            ),
            ActionDescriptor(
                id: "workspace.newOnMachine",
                title: String(localized: "action.workspace.newOnMachine", defaultValue: "New Workspace on Machine…", table: "WorkspaceActions", bundle: .module),
                keywords: ["create", "remote", "ssh", "cloud", "session"], category: .workspace, symbol: "server.rack",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [CatalogArgument.machineMachine], targets: [.workspace], cliName: "workspace new-on-machine", startsTerminal: true
            ),
            ActionDescriptor(
                id: "workspace.newInSameDirectory",
                title: String(localized: "action.workspace.newInSameDirectory", defaultValue: "New Workspace in Same Directory", table: "WorkspaceActions", bundle: .module),
                keywords: ["create", "cwd", "folder", "path"], category: .workspace, symbol: "folder",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace new-in-same-directory", startsTerminal: true
            ),
            ActionDescriptor(
                id: "workspace.duplicate",
                title: String(localized: "action.workspace.duplicate", defaultValue: "Duplicate Workspace", table: "WorkspaceActions", bundle: .module),
                keywords: ["copy", "clone", "layout"], category: .workspace, symbol: "plus.square.on.square",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace duplicate", startsTerminal: true
            ),
            ActionDescriptor(
                id: "workspace.duplicateTerminalsOnly",
                title: String(localized: "action.workspace.duplicateTerminalsOnly", defaultValue: "Duplicate Workspace without Browser Tabs", table: "WorkspaceActions", bundle: .module),
                keywords: ["copy", "clone", "layout", "terminal"], category: .workspace, symbol: "terminal",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace duplicate-terminals-only", startsTerminal: true
            ),
            ActionDescriptor(
                id: "workspace.setIcon",
                title: String(localized: "action.workspace.setIcon", defaultValue: "Set Workspace Icon…", table: "WorkspaceActions", bundle: .module),
                keywords: ["emoji", "symbol", "badge"], category: .workspace, symbol: "face.smiling",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [CatalogArgument.iconString.optional], targets: [.workspace],
                cliName: "workspace set-icon"
            ),
            ActionDescriptor(
                id: "workspace.clearIcon",
                title: String(localized: "action.workspace.clearIcon", defaultValue: "Clear Workspace Icon", table: "WorkspaceActions", bundle: .module),
                keywords: ["emoji", "symbol", "reset"], category: .workspace, symbol: "xmark.circle",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace clear-icon"
            ),
            ActionDescriptor(
                id: "workspace.moveToBottom",
                title: String(localized: "action.workspace.moveToBottom", defaultValue: "Move Workspace to Bottom", table: "WorkspaceActions", bundle: .module),
                keywords: ["reorder", "last", "end"], category: .workspace, symbol: "arrow.down.to.line",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace move-to-bottom"
            ),
            ActionDescriptor(
                id: "workspace.moveToNewGroup",
                title: String(localized: "action.workspace.moveToNewGroup", defaultValue: "Move Workspace to New Group", table: "WorkspaceActions", bundle: .module),
                keywords: ["group", "section"], category: .workspace, symbol: "folder.badge.plus",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [CatalogArgument.nameString.optional], targets: [.workspace], cliName: "workspace move-to-new-group"
            ),
            ActionDescriptor(
                id: "workspace.closeOthersInGroup",
                title: String(localized: "action.workspace.closeOthersInGroup", defaultValue: "Close Other Workspaces in Group", table: "WorkspaceActions", bundle: .module),
                keywords: ["close", "group"], category: .workspace, symbol: "xmark.rectangle",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace close-others-in-group", destructive: true
            ),
            ActionDescriptor(
                id: "workspace.selectFirst",
                title: String(localized: "action.workspace.selectFirst", defaultValue: "Select First Workspace", table: "WorkspaceActions", bundle: .module),
                keywords: ["switch", "top"], category: .workspace, symbol: "arrow.up.to.line.compact",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace first"
            ),
            ActionDescriptor(
                id: "workspace.selectLast",
                title: String(localized: "action.workspace.selectLast", defaultValue: "Select Last Workspace", table: "WorkspaceActions", bundle: .module),
                keywords: ["switch", "bottom"], category: .workspace, symbol: "arrow.down.to.line.compact",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace last"
            ),
            ActionDescriptor(
                id: "workspace.selectLastUsed",
                title: String(localized: "action.workspace.selectLastUsed", defaultValue: "Switch to Last Used Workspace", table: "WorkspaceActions", bundle: .module),
                keywords: ["switch", "recent", "previous", "mru", "toggle", "alternate"], defaultShortcut: Shortcut("`", modifiers: [.control, .command]), category: .workspace, symbol: "arrow.left.arrow.right",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace last-used"
            ),
            ActionDescriptor(
                id: "workspace.sortByName",
                title: String(localized: "action.workspace.sortByName", defaultValue: "Sort Workspaces by Name", table: "WorkspaceActions", bundle: .module),
                keywords: ["sort", "alphabetical", "order"], category: .workspace, symbol: "textformat.abc",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace sort-by-name"
            ),
            ActionDescriptor(
                id: "workspace.sortByLastUsed",
                title: String(localized: "action.workspace.sortByLastUsed", defaultValue: "Sort Workspaces by Last Used", table: "WorkspaceActions", bundle: .module),
                keywords: ["sort", "recent", "order"], category: .workspace, symbol: "clock",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace sort-by-last-used"
            ),
            ActionDescriptor(
                id: "workspace.sortByDirectory",
                title: String(localized: "action.workspace.sortByDirectory", defaultValue: "Sort Workspaces by Directory", table: "WorkspaceActions", bundle: .module),
                keywords: ["sort", "cwd", "folder", "repo", "order"], category: .workspace, symbol: "folder",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace sort-by-directory"
            ),
            ActionDescriptor(
                id: "workspaceGroup.collapseAll",
                title: String(localized: "action.workspaceGroup.collapseAll", defaultValue: "Collapse All Groups", table: "WorkspaceActions", bundle: .module),
                keywords: ["fold", "group", "section"], category: .workspace, symbol: "rectangle.compress.vertical",
                surfaces: [.palette, .keyboard, .contextMenu], cliName: "workspace-group collapse-all"
            ),
            ActionDescriptor(
                id: "workspaceGroup.expandAll",
                title: String(localized: "action.workspaceGroup.expandAll", defaultValue: "Expand All Groups", table: "WorkspaceActions", bundle: .module),
                keywords: ["unfold", "group", "section"], category: .workspace, symbol: "rectangle.expand.vertical",
                surfaces: [.palette, .keyboard, .contextMenu], cliName: "workspace-group expand-all"
            ),
            ActionDescriptor(
                id: "workspace.copyPath",
                title: String(localized: "action.workspace.copyPath", defaultValue: "Copy Workspace Path", table: "WorkspaceActions", bundle: .module),
                keywords: ["cwd", "directory", "folder", "clipboard"], category: .workspace, symbol: "doc.on.clipboard",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.workspace], cliName: "workspace copy-path"
            ),
            ActionDescriptor(
                id: "workspace.mergeInto",
                title: String(localized: "action.workspace.mergeInto", defaultValue: "Merge Workspace into…", table: "WorkspaceActions", bundle: .module),
                keywords: ["combine", "join", "move tabs"], category: .workspace, symbol: "arrow.triangle.merge",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [CatalogArgument.intoWorkspace], targets: [.workspace], cliName: "workspace merge-into"
            ),
            ActionDescriptor(
                id: "pane.moveToNewWorkspace",
                title: String(localized: "action.pane.moveToNewWorkspace", defaultValue: "Move Pane to New Workspace", table: "WorkspaceActions", bundle: .module),
                keywords: ["split", "detach", "tear off"], category: .pane, symbol: "rectangle.portrait.and.arrow.right",
                surfaces: [.palette, .keyboard, .contextMenu], targets: [.pane], cliName: "pane move-to-new-workspace"
            ),
        ]
    }
}
