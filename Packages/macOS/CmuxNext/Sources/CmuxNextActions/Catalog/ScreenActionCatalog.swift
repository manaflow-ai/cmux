// Screen actions (windows inside a workspace). Screens have no UI
// until a workspace holds two or more (REWRITE.md goal 5); creating one is
// only possible from the palette, a user-bound shortcut, or the CLI, so
// `screen.new` and `screen.newWith` have no default shortcut and no menu.
// Titles live in ScreenActions.xcstrings (21 languages).

nonisolated enum ScreenActionCatalog: ActionCatalogGroup {
    static func screen(
        _ id: ActionID, _ title: String, _ symbol: String, cli: String, keywords: [String],
        surfaces: ActionSurfaces = [.palette, .contextMenu], targets: [ActionTargetKind] = [.screen],
        arguments: [ActionArgument] = [], family: ShortcutFamily? = nil, destructive: Bool = false,
        startsTerminal: Bool = false
    ) -> ActionDescriptor {
        ActionDescriptor(
            id: id, title: title, keywords: ["screen"] + keywords, shortcutFamily: family, category: .screen, symbol: symbol,
            surfaces: surfaces, arguments: arguments, targets: targets, cliName: cli, destructive: destructive,
            startsTerminal: startsTerminal
        )
    }

    static func descriptors() -> [ActionDescriptor] {
        screenLifecycleActions() + screenNavigationActions() + screenAppearanceActions() + screenMoveActions()
    }

    private static func screenLifecycleActions() -> [ActionDescriptor] {
        [
            screen("screen.new", String(localized: "action.screen.new", defaultValue: "New Screen", table: "ScreenActions", bundle: .module),
                   "rectangle.stack.badge.plus", cli: "screen new", keywords: ["window", "create"], surfaces: [.palette],
                   startsTerminal: true),
            screen("screen.newWith", String(localized: "action.screen.newWith", defaultValue: "New Screen with…", table: "ScreenActions", bundle: .module),
                   "rectangle.stack.badge.plus", cli: "screen new-with", keywords: ["window", "create", "name", "directory"],
                   surfaces: [.palette], arguments: [CatalogArgument.nameString, CatalogArgument.colorChoice.optional,
                                                     CatalogArgument.iconString.optional, CatalogArgument.cwdString.optional],
                   startsTerminal: true),
            screen("screen.duplicate", String(localized: "action.screen.duplicate", defaultValue: "Duplicate Screen", table: "ScreenActions", bundle: .module),
                   "plus.square.on.square", cli: "screen duplicate", keywords: ["copy", "clone"], startsTerminal: true),
            screen("screen.close", String(localized: "action.screen.close", defaultValue: "Close Screen", table: "ScreenActions", bundle: .module),
                   "xmark.rectangle.portrait", cli: "screen close", keywords: ["remove"]),
            screen("screen.closeOthers", String(localized: "action.screen.closeOthers", defaultValue: "Close Other Screens", table: "ScreenActions", bundle: .module),
                   "xmark.square", cli: "screen close-others", keywords: ["remove"], destructive: true),
            screen("screen.closeToRight", String(localized: "action.screen.closeToRight", defaultValue: "Close Screens to the Right", table: "ScreenActions", bundle: .module),
                   "arrow.right.to.line", cli: "screen close-right", keywords: ["remove"], destructive: true),
            screen("screen.closeToLeft", String(localized: "action.screen.closeToLeft", defaultValue: "Close Screens to the Left", table: "ScreenActions", bundle: .module),
                   "arrow.left.to.line", cli: "screen close-left", keywords: ["remove"], destructive: true),
            screen("screen.reopenClosed", String(localized: "action.screen.reopenClosed", defaultValue: "Reopen Closed Screen", table: "ScreenActions", bundle: .module),
                   "arrow.uturn.backward.square", cli: "screen reopen-closed", keywords: ["undo", "restore"], surfaces: [.palette],
                   targets: []),
        ]
    }

    private static func screenNavigationActions() -> [ActionDescriptor] {
        [
            screen("screen.next", String(localized: "action.screen.next", defaultValue: "Next Screen", table: "ScreenActions", bundle: .module),
                   "chevron.right.2", cli: "screen next", keywords: ["switch"], surfaces: [.palette, .keyboard]),
            screen("screen.previous", String(localized: "action.screen.previous", defaultValue: "Previous Screen", table: "ScreenActions", bundle: .module),
                   "chevron.left.2", cli: "screen previous", keywords: ["switch"], surfaces: [.palette, .keyboard]),
            screen("screen.select", String(localized: "action.screen.select", defaultValue: "Select Screen 1…9", table: "ScreenActions", bundle: .module),
                   "number.square", cli: "screen select", keywords: ["switch", "index"], surfaces: [.palette, .keyboard],
                   arguments: [CatalogArgument.indexNumber], family: .digits),
            screen("screen.selectLast", String(localized: "action.screen.selectLast", defaultValue: "Select Last Screen", table: "ScreenActions", bundle: .module),
                   "9.square", cli: "screen select-last", keywords: ["switch", "end"], surfaces: [.palette, .keyboard]),
        ]
    }

    private static func screenAppearanceActions() -> [ActionDescriptor] {
        [
            screen("screen.rename", String(localized: "action.screen.rename", defaultValue: "Rename Screen…", table: "ScreenActions", bundle: .module),
                   "pencil", cli: "screen rename", keywords: ["title", "name"], arguments: [CatalogArgument.nameString.optional]),
            screen("screen.clearName", String(localized: "action.screen.clearName", defaultValue: "Clear Screen Name", table: "ScreenActions", bundle: .module),
                   "eraser", cli: "screen clear-name", keywords: ["title", "name", "reset"]),
            screen("screen.setColor", String(localized: "action.screen.setColor", defaultValue: "Set Screen Color…", table: "ScreenActions", bundle: .module),
                   "paintpalette", cli: "screen set-color", keywords: ["color"], arguments: [CatalogArgument.colorChoice]),
            screen("screen.clearColor", String(localized: "action.screen.clearColor", defaultValue: "Remove Screen Color", table: "ScreenActions", bundle: .module),
                   "circle.slash", cli: "screen clear-color", keywords: ["color", "reset"]),
            screen("screen.setIcon", String(localized: "action.screen.setIcon", defaultValue: "Set Screen Icon…", table: "ScreenActions", bundle: .module),
                   "face.smiling", cli: "screen set-icon", keywords: ["icon", "emoji", "symbol"], arguments: [CatalogArgument.iconString]),
            screen("screen.clearIcon", String(localized: "action.screen.clearIcon", defaultValue: "Remove Screen Icon", table: "ScreenActions", bundle: .module),
                   "circle.dashed", cli: "screen clear-icon", keywords: ["icon", "emoji", "reset"]),
            screen("screen.togglePin", String(localized: "action.screen.togglePin", defaultValue: "Pin or Unpin Screen", table: "ScreenActions", bundle: .module),
                   "pin", cli: "screen toggle-pin", keywords: ["pin", "unpin", "keep"]),
        ] + GroupColor9.names.map { color in
            screen(ActionID(rawValue: "screen.color.\(color)"), GroupColor9.screenTitle(color), "circle.fill",
                   cli: "screen color-\(color)", keywords: ["color", color])
        }
    }

    private static func screenMoveActions() -> [ActionDescriptor] {
        [
            screen("screen.moveLeft", String(localized: "action.screen.moveLeft", defaultValue: "Move Screen Left", table: "ScreenActions", bundle: .module),
                   "arrow.left", cli: "screen move-left", keywords: ["reorder"], surfaces: [.palette, .keyboard, .contextMenu]),
            screen("screen.moveRight", String(localized: "action.screen.moveRight", defaultValue: "Move Screen Right", table: "ScreenActions", bundle: .module),
                   "arrow.right", cli: "screen move-right", keywords: ["reorder"], surfaces: [.palette, .keyboard, .contextMenu]),
            screen("screen.moveToWorkspace", String(localized: "action.screen.moveToWorkspace", defaultValue: "Move Screen to Workspace…", table: "ScreenActions", bundle: .module),
                   "arrow.right.square", cli: "screen move-to-workspace", keywords: ["workspace", "move"],
                   arguments: [CatalogArgument.workspaceWorkspace]),
            screen("screen.moveToNewWorkspace", String(localized: "action.screen.moveToNewWorkspace", defaultValue: "Move Screen to New Workspace", table: "ScreenActions", bundle: .module),
                   "plus.rectangle.on.rectangle", cli: "screen move-to-new-workspace", keywords: ["workspace", "move", "detach"]),
            screen("screen.moveToNewWindow", String(localized: "action.screen.moveToNewWindow", defaultValue: "Move Screen to New Window", table: "ScreenActions", bundle: .module),
                   "macwindow.badge.plus", cli: "screen move-to-new-window", keywords: ["window", "move", "detach"]),
        ]
    }
}

/// The nine group color names, shared by screen and screen group
/// color actions and context submenus.
nonisolated enum GroupColor9 {
    static let names = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]

    static func screenTitle(_ color: String) -> String {
        switch color {
        case "grey": String(localized: "action.screen.color.grey", defaultValue: "Screen Color: Grey", table: "ScreenActions", bundle: .module)
        case "blue": String(localized: "action.screen.color.blue", defaultValue: "Screen Color: Blue", table: "ScreenActions", bundle: .module)
        case "red": String(localized: "action.screen.color.red", defaultValue: "Screen Color: Red", table: "ScreenActions", bundle: .module)
        case "yellow": String(localized: "action.screen.color.yellow", defaultValue: "Screen Color: Yellow", table: "ScreenActions", bundle: .module)
        case "green": String(localized: "action.screen.color.green", defaultValue: "Screen Color: Green", table: "ScreenActions", bundle: .module)
        case "pink": String(localized: "action.screen.color.pink", defaultValue: "Screen Color: Pink", table: "ScreenActions", bundle: .module)
        case "purple": String(localized: "action.screen.color.purple", defaultValue: "Screen Color: Purple", table: "ScreenActions", bundle: .module)
        case "cyan": String(localized: "action.screen.color.cyan", defaultValue: "Screen Color: Cyan", table: "ScreenActions", bundle: .module)
        default: String(localized: "action.screen.color.orange", defaultValue: "Screen Color: Orange", table: "ScreenActions", bundle: .module)
        }
    }

    static func groupTitle(_ color: String) -> String {
        switch color {
        case "grey": String(localized: "action.screenGroup.color.grey", defaultValue: "Screen Group Color: Grey", table: "ScreenActions", bundle: .module)
        case "blue": String(localized: "action.screenGroup.color.blue", defaultValue: "Screen Group Color: Blue", table: "ScreenActions", bundle: .module)
        case "red": String(localized: "action.screenGroup.color.red", defaultValue: "Screen Group Color: Red", table: "ScreenActions", bundle: .module)
        case "yellow": String(localized: "action.screenGroup.color.yellow", defaultValue: "Screen Group Color: Yellow", table: "ScreenActions", bundle: .module)
        case "green": String(localized: "action.screenGroup.color.green", defaultValue: "Screen Group Color: Green", table: "ScreenActions", bundle: .module)
        case "pink": String(localized: "action.screenGroup.color.pink", defaultValue: "Screen Group Color: Pink", table: "ScreenActions", bundle: .module)
        case "purple": String(localized: "action.screenGroup.color.purple", defaultValue: "Screen Group Color: Purple", table: "ScreenActions", bundle: .module)
        case "cyan": String(localized: "action.screenGroup.color.cyan", defaultValue: "Screen Group Color: Cyan", table: "ScreenActions", bundle: .module)
        default: String(localized: "action.screenGroup.color.orange", defaultValue: "Screen Group Color: Orange", table: "ScreenActions", bundle: .module)
        }
    }
}
