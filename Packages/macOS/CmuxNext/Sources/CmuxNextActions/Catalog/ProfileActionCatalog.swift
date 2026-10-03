// Rooms (plans/cmux-next/data-model.md 8): switchable sets of workspaces,
// groups and theme; the wire calls them profiles. Titles live in
// ProfileActions.xcstrings.

nonisolated enum ProfileActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "space.new",
                title: String(localized: "action.space.new", defaultValue: "New Space", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "create"], category: .workspace, symbol: "circle.badge.plus",
                surfaces: [.palette, .keyboard, .menu, .contextMenu],
                arguments: [CatalogArgument.nameString.optional, CatalogArgument.colorChoice.optional, CatalogArgument.iconString.optional],
                cliName: "space create", mainMenu: .window
            ),
            ActionDescriptor(
                id: "space.newWindow",
                title: String(localized: "action.space.newWindow", defaultValue: "New Window in Space…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "window"], category: .workspace, symbol: "macwindow.badge.plus",
                surfaces: [.palette, .menu, .contextMenu], arguments: [CatalogArgument.roomRoom], targets: [.profile],
                cliName: "space new-window", mainMenu: .file
            ),
            ActionDescriptor(
                id: "space.newWorkspace",
                title: String(localized: "action.space.newWorkspace", defaultValue: "New Workspace in Space…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "workspace"], category: .workspace, symbol: "plus.rectangle.on.rectangle",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.roomRoom], targets: [.profile],
                cliName: "space new-workspace", startsTerminal: true
            ),
            ActionDescriptor(
                id: "space.rename",
                title: String(localized: "action.space.rename", defaultValue: "Rename Space…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "name"], category: .workspace, symbol: "pencil",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.nameString.optional], targets: [.profile],
                cliName: "space rename"
            ),
            ActionDescriptor(
                id: "space.setColor",
                title: String(localized: "action.space.setColor", defaultValue: "Set Space Color…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color"], category: .workspace, symbol: "paintpalette",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.colorChoice], targets: [.profile],
                cliName: "space set-color"
            ),
            ActionDescriptor(
                id: "space.color.grey",
                title: String(localized: "action.space.color.grey", defaultValue: "Space Color: Grey", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "grey"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "space color-grey"
            ),
            ActionDescriptor(
                id: "space.color.blue",
                title: String(localized: "action.space.color.blue", defaultValue: "Space Color: Blue", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "blue"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "space color-blue"
            ),
            ActionDescriptor(
                id: "space.color.red",
                title: String(localized: "action.space.color.red", defaultValue: "Space Color: Red", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "red"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "space color-red"
            ),
            ActionDescriptor(
                id: "space.color.yellow",
                title: String(localized: "action.space.color.yellow", defaultValue: "Space Color: Yellow", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "yellow"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "space color-yellow"
            ),
            ActionDescriptor(
                id: "space.color.green",
                title: String(localized: "action.space.color.green", defaultValue: "Space Color: Green", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "green"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "space color-green"
            ),
            ActionDescriptor(
                id: "space.color.pink",
                title: String(localized: "action.space.color.pink", defaultValue: "Space Color: Pink", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "pink"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "space color-pink"
            ),
            ActionDescriptor(
                id: "space.color.purple",
                title: String(localized: "action.space.color.purple", defaultValue: "Space Color: Purple", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "purple"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "space color-purple"
            ),
            ActionDescriptor(
                id: "space.color.cyan",
                title: String(localized: "action.space.color.cyan", defaultValue: "Space Color: Cyan", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "cyan"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "space color-cyan"
            ),
            ActionDescriptor(
                id: "space.color.orange",
                title: String(localized: "action.space.color.orange", defaultValue: "Space Color: Orange", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "orange"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "space color-orange"
            ),
            ActionDescriptor(
                id: "space.clearColor",
                title: String(localized: "action.space.clearColor", defaultValue: "Clear Space Color", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "reset"], category: .workspace, symbol: "circle.slash",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "space clear-color"
            ),
            ActionDescriptor(
                id: "space.setIcon",
                title: String(localized: "action.space.setIcon", defaultValue: "Set Space Icon…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "icon", "emoji", "symbol"], category: .workspace, symbol: "face.smiling",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.iconString], targets: [.profile],
                cliName: "space set-icon"
            ),
            ActionDescriptor(
                id: "space.clearIcon",
                title: String(localized: "action.space.clearIcon", defaultValue: "Clear Space Icon", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "icon", "reset"], category: .workspace, symbol: "circle.dashed",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "space clear-icon"
            ),
            ActionDescriptor(
                id: "space.setDefaults",
                title: String(localized: "action.space.setDefaults", defaultValue: "Set Space Terminal Defaults…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "directory", "cwd", "environment", "env"], category: .workspace, symbol: "terminal",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.cwdString.optional, CatalogArgument.envString.optional],
                targets: [.profile], cliName: "space set-defaults"
            ),
            ActionDescriptor(
                id: "space.delete",
                title: String(localized: "action.space.delete", defaultValue: "Delete Space…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "remove"], category: .workspace, symbol: "trash",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.moveToRoom.optional], targets: [.profile],
                cliName: "space delete", destructive: true
            ),
            ActionDescriptor(
                id: "space.moveLeft",
                title: String(localized: "action.space.moveLeft", defaultValue: "Move Space Left", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "reorder"], category: .workspace, symbol: "arrow.left",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "space move-left"
            ),
            ActionDescriptor(
                id: "space.moveRight",
                title: String(localized: "action.space.moveRight", defaultValue: "Move Space Right", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "reorder"], category: .workspace, symbol: "arrow.right",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "space move-right"
            ),
            ActionDescriptor(
                id: "space.move",
                title: String(localized: "action.space.move", defaultValue: "Move Space to Position…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "reorder"], category: .workspace, symbol: "arrow.left.arrow.right",
                surfaces: [.palette], arguments: [CatalogArgument.positionNumber], targets: [.profile], cliName: "space move"
            ),
            ActionDescriptor(
                id: "space.next",
                title: String(localized: "action.space.next", defaultValue: "Next Space", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "switch"], defaultShortcut: Shortcut("]", modifiers: [.option, .command]),
                category: .workspace, symbol: "chevron.right.circle", surfaces: [.palette, .keyboard, .menu], cliName: "space next",
                mainMenu: .window
            ),
            ActionDescriptor(
                id: "space.previous",
                title: String(localized: "action.space.previous", defaultValue: "Previous Space", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "switch"], defaultShortcut: Shortcut("[", modifiers: [.option, .command]),
                category: .workspace, symbol: "chevron.left.circle", surfaces: [.palette, .keyboard, .menu], cliName: "space previous",
                mainMenu: .window
            ),
            ActionDescriptor(
                id: "space.selectByNumber",
                title: String(localized: "action.space.selectByNumber", defaultValue: "Select Space 1…9", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "switch", "index"], defaultShortcut: Shortcut("1", modifiers: [.control]),
                shortcutFamily: .digits, category: .workspace, symbol: "number.circle", surfaces: [.keyboard, .menu],
                arguments: [CatalogArgument.indexNumber], cliName: "space select-1-9", mainMenu: .window
            ),
            ActionDescriptor(
                id: "space.switch",
                title: String(localized: "action.space.switch", defaultValue: "Switch to Space…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "switch"], category: .workspace, symbol: "circle.grid.2x1",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.roomRoom], targets: [.profile, .window],
                cliName: "space switch"
            ),
            ActionDescriptor(
                id: "workspace.moveToSpace",
                title: String(localized: "action.workspace.moveToSpace", defaultValue: "Move Workspace to Space…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "move"], category: .workspace, symbol: "arrow.right.circle",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.roomRoom], targets: [.workspace],
                cliName: "workspace move-to-space"
            ),
            ActionDescriptor(
                id: "workspace.duplicateToSpace",
                title: String(localized: "action.workspace.duplicateToSpace", defaultValue: "Duplicate Workspace into Space…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "copy", "duplicate"], category: .workspace, symbol: "plus.square.on.square",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.roomRoom], targets: [.workspace],
                cliName: "workspace duplicate-to-space", startsTerminal: true
            ),
            ActionDescriptor(
                id: "workspaceGroup.moveToSpace",
                title: String(localized: "action.workspaceGroup.moveToSpace", defaultValue: "Move Workspace Group to Space…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "group", "move"], category: .workspace, symbol: "arrow.right.circle",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.roomRoom], targets: [.workspaceGroup],
                cliName: "workspace-group move-to-space"
            ),
        ]
    }
}
