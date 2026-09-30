// Rooms (plans/cmux-next/data-model.md 8): switchable sets of workspaces,
// groups and theme; the wire calls them profiles. Titles live in
// ProfileActions.xcstrings.

nonisolated extension ActionCatalog {
    static func profileActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "room.new",
                title: String(localized: "action.room.new", defaultValue: "New Room", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "create"], category: .workspace, symbol: "circle.badge.plus",
                surfaces: [.palette, .keyboard, .menu, .contextMenu],
                arguments: [CatalogArgument.nameString.optional, CatalogArgument.colorChoice.optional, CatalogArgument.iconString.optional],
                cliName: "room create", mainMenu: .window
            ),
            ActionDescriptor(
                id: "room.newWindow",
                title: String(localized: "action.room.newWindow", defaultValue: "New Window in Room…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "window"], category: .workspace, symbol: "macwindow.badge.plus",
                surfaces: [.palette, .menu, .contextMenu], arguments: [CatalogArgument.roomRoom], targets: [.profile],
                cliName: "room new-window", mainMenu: .file
            ),
            ActionDescriptor(
                id: "room.newWorkspace",
                title: String(localized: "action.room.newWorkspace", defaultValue: "New Workspace in Room…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "workspace"], category: .workspace, symbol: "plus.rectangle.on.rectangle",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.roomRoom], targets: [.profile],
                cliName: "room new-workspace", startsTerminal: true
            ),
            ActionDescriptor(
                id: "room.rename",
                title: String(localized: "action.room.rename", defaultValue: "Rename Room…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "name"], category: .workspace, symbol: "pencil",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.nameString.optional], targets: [.profile],
                cliName: "room rename"
            ),
            ActionDescriptor(
                id: "room.setColor",
                title: String(localized: "action.room.setColor", defaultValue: "Set Room Color…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color"], category: .workspace, symbol: "paintpalette",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.colorChoice], targets: [.profile],
                cliName: "room set-color"
            ),
            ActionDescriptor(
                id: "room.color.grey",
                title: String(localized: "action.room.color.grey", defaultValue: "Room Color: Grey", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "grey"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "room color-grey"
            ),
            ActionDescriptor(
                id: "room.color.blue",
                title: String(localized: "action.room.color.blue", defaultValue: "Room Color: Blue", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "blue"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "room color-blue"
            ),
            ActionDescriptor(
                id: "room.color.red",
                title: String(localized: "action.room.color.red", defaultValue: "Room Color: Red", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "red"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "room color-red"
            ),
            ActionDescriptor(
                id: "room.color.yellow",
                title: String(localized: "action.room.color.yellow", defaultValue: "Room Color: Yellow", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "yellow"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "room color-yellow"
            ),
            ActionDescriptor(
                id: "room.color.green",
                title: String(localized: "action.room.color.green", defaultValue: "Room Color: Green", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "green"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "room color-green"
            ),
            ActionDescriptor(
                id: "room.color.pink",
                title: String(localized: "action.room.color.pink", defaultValue: "Room Color: Pink", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "pink"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "room color-pink"
            ),
            ActionDescriptor(
                id: "room.color.purple",
                title: String(localized: "action.room.color.purple", defaultValue: "Room Color: Purple", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "purple"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "room color-purple"
            ),
            ActionDescriptor(
                id: "room.color.cyan",
                title: String(localized: "action.room.color.cyan", defaultValue: "Room Color: Cyan", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "cyan"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "room color-cyan"
            ),
            ActionDescriptor(
                id: "room.color.orange",
                title: String(localized: "action.room.color.orange", defaultValue: "Room Color: Orange", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "orange"], category: .workspace, symbol: "circle.fill",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "room color-orange"
            ),
            ActionDescriptor(
                id: "room.clearColor",
                title: String(localized: "action.room.clearColor", defaultValue: "Clear Room Color", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "color", "reset"], category: .workspace, symbol: "circle.slash",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "room clear-color"
            ),
            ActionDescriptor(
                id: "room.setIcon",
                title: String(localized: "action.room.setIcon", defaultValue: "Set Room Icon…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "icon", "emoji", "symbol"], category: .workspace, symbol: "face.smiling",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.iconString], targets: [.profile],
                cliName: "room set-icon"
            ),
            ActionDescriptor(
                id: "room.clearIcon",
                title: String(localized: "action.room.clearIcon", defaultValue: "Clear Room Icon", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "icon", "reset"], category: .workspace, symbol: "circle.dashed",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "room clear-icon"
            ),
            ActionDescriptor(
                id: "room.setDefaults",
                title: String(localized: "action.room.setDefaults", defaultValue: "Set Room Terminal Defaults…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "directory", "cwd", "environment", "env"], category: .workspace, symbol: "terminal",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.cwdString.optional, CatalogArgument.envString.optional],
                targets: [.profile], cliName: "room set-defaults"
            ),
            ActionDescriptor(
                id: "room.delete",
                title: String(localized: "action.room.delete", defaultValue: "Delete Room…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "remove"], category: .workspace, symbol: "trash",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.moveToRoom.optional], targets: [.profile],
                cliName: "room delete", destructive: true
            ),
            ActionDescriptor(
                id: "room.moveLeft",
                title: String(localized: "action.room.moveLeft", defaultValue: "Move Room Left", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "reorder"], category: .workspace, symbol: "arrow.left",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "room move-left"
            ),
            ActionDescriptor(
                id: "room.moveRight",
                title: String(localized: "action.room.moveRight", defaultValue: "Move Room Right", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "reorder"], category: .workspace, symbol: "arrow.right",
                surfaces: [.palette, .contextMenu], targets: [.profile], cliName: "room move-right"
            ),
            ActionDescriptor(
                id: "room.move",
                title: String(localized: "action.room.move", defaultValue: "Move Room to Position…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "reorder"], category: .workspace, symbol: "arrow.left.arrow.right",
                surfaces: [.palette], arguments: [CatalogArgument.positionNumber], targets: [.profile], cliName: "room move"
            ),
            ActionDescriptor(
                id: "room.next",
                title: String(localized: "action.room.next", defaultValue: "Next Room", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "switch"], defaultShortcut: Shortcut("]", modifiers: [.option, .command]),
                category: .workspace, symbol: "chevron.right.circle", surfaces: [.palette, .keyboard, .menu], cliName: "room next",
                mainMenu: .window
            ),
            ActionDescriptor(
                id: "room.previous",
                title: String(localized: "action.room.previous", defaultValue: "Previous Room", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "switch"], defaultShortcut: Shortcut("[", modifiers: [.option, .command]),
                category: .workspace, symbol: "chevron.left.circle", surfaces: [.palette, .keyboard, .menu], cliName: "room previous",
                mainMenu: .window
            ),
            ActionDescriptor(
                id: "room.selectByNumber",
                title: String(localized: "action.room.selectByNumber", defaultValue: "Select Room 1…9", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "switch", "index"], defaultShortcut: Shortcut("1", modifiers: [.control, .option]),
                shortcutFamily: .digits, category: .workspace, symbol: "number.circle", surfaces: [.keyboard, .menu],
                arguments: [CatalogArgument.indexNumber], cliName: "room select-1-9", mainMenu: .window
            ),
            ActionDescriptor(
                id: "room.switch",
                title: String(localized: "action.room.switch", defaultValue: "Switch to Room…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "switch"], category: .workspace, symbol: "circle.grid.2x1",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.roomRoom], targets: [.profile, .window],
                cliName: "room switch"
            ),
            ActionDescriptor(
                id: "workspace.moveToRoom",
                title: String(localized: "action.workspace.moveToRoom", defaultValue: "Move Workspace to Room…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "move"], category: .workspace, symbol: "arrow.right.circle",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.roomRoom], targets: [.workspace],
                cliName: "workspace move-to-room"
            ),
            ActionDescriptor(
                id: "workspace.duplicateToRoom",
                title: String(localized: "action.workspace.duplicateToRoom", defaultValue: "Duplicate Workspace into Room…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "space", "copy", "duplicate"], category: .workspace, symbol: "plus.square.on.square",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.roomRoom], targets: [.workspace],
                cliName: "workspace duplicate-to-room", startsTerminal: true
            ),
            ActionDescriptor(
                id: "workspaceGroup.moveToRoom",
                title: String(localized: "action.workspaceGroup.moveToRoom", defaultValue: "Move Workspace Group to Room…", table: "ProfileActions", bundle: .module),
                keywords: ["room", "profile", "group", "move"], category: .workspace, symbol: "arrow.right.circle",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.roomRoom], targets: [.workspaceGroup],
                cliName: "workspace-group move-to-room"
            ),
        ]
    }
}
