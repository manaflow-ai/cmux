import Foundation

/// Argument definitions shared by catalog actions. Titles live in
/// Localizable.xcstrings under `argument.<name>` and `argument.value.<value>`.
nonisolated enum CatalogArgument {
    static var workspaceWorkspace: ActionArgument {
        ActionArgument(name: "workspace", title: String(localized: "argument.workspace", defaultValue: "Workspace", bundle: .module), kind: .target(.workspace))
    }

    static var processString: ActionArgument {
        ActionArgument(name: "process", title: String(localized: "argument.process", defaultValue: "Process", bundle: .module), kind: .string)
    }

    static var indexNumber: ActionArgument {
        ActionArgument(name: "index", title: String(localized: "argument.index", defaultValue: "Number", bundle: .module), kind: .int(1...9))
    }

    static var windowWindow: ActionArgument {
        ActionArgument(name: "window", title: String(localized: "argument.window", defaultValue: "Window", bundle: .module), kind: .target(.window))
    }

    static var nameString: ActionArgument {
        ActionArgument(name: "name", title: String(localized: "argument.name", defaultValue: "Name", bundle: .module), kind: .string)
    }

    static var descriptionString: ActionArgument {
        ActionArgument(name: "description", title: String(localized: "argument.description", defaultValue: "Description", bundle: .module), kind: .string)
    }

    static var statusChoice: ActionArgument {
        ActionArgument(name: "status", title: String(localized: "argument.status", defaultValue: "Status", bundle: .module), kind: .enumeration([choice("auto"), choice("todo"), choice("inProgress"), choice("review"), choice("done"), choice("blocked")]))
    }

    static var textString: ActionArgument {
        ActionArgument(name: "text", title: String(localized: "argument.text", defaultValue: "Text", bundle: .module), kind: .string)
    }

    static var colorChoice: ActionArgument {
        ActionArgument(name: "color", title: String(localized: "argument.color", defaultValue: "Color", bundle: .module), kind: .enumeration([choice("grey"), choice("blue"), choice("red"), choice("yellow"), choice("green"), choice("pink"), choice("purple"), choice("cyan"), choice("orange")]))
    }

    static var templateString: ActionArgument {
        ActionArgument(name: "template", title: String(localized: "argument.template", defaultValue: "Template", bundle: .module), kind: .string)
    }

    static var groupWorkspaceGroup: ActionArgument {
        ActionArgument(name: "group", title: String(localized: "argument.group", defaultValue: "Group", bundle: .module), kind: .target(.workspaceGroup))
    }

    static var panePane: ActionArgument {
        ActionArgument(name: "pane", title: String(localized: "argument.pane", defaultValue: "Pane", bundle: .module), kind: .target(.pane))
    }

    static var tabTab: ActionArgument {
        ActionArgument(name: "tab", title: String(localized: "argument.tab", defaultValue: "Tab", bundle: .module), kind: .target(.tab))
    }

    static var groupTabGroup: ActionArgument {
        ActionArgument(name: "group", title: String(localized: "argument.group", defaultValue: "Group", bundle: .module), kind: .target(.tabGroup))
    }

    static var groupScreenGroup: ActionArgument {
        ActionArgument(name: "group", title: String(localized: "argument.group", defaultValue: "Group", bundle: .module), kind: .target(.screenGroup))
    }

    /// A saved group id.
    static var savedString: ActionArgument {
        ActionArgument(name: "saved", title: String(localized: "argument.savedGroup", defaultValue: "Saved Group", table: "ScreenActions", bundle: .module), kind: .string)
    }

    static var directionChoice: ActionArgument {
        ActionArgument(name: "direction", title: String(localized: "argument.direction", defaultValue: "Direction", bundle: .module), kind: .enumeration([choice("right"), choice("down"), choice("left"), choice("up")]))
    }

    /// A sticky column's viewport edge (plans/cmux-next/sticky-column.md).
    static var edgeChoice: ActionArgument {
        ActionArgument(name: "edge", title: String(localized: "argument.edge", defaultValue: "Edge", bundle: .module),
                       kind: .enumeration([choice("right"), choice("left")]))
    }

    /// Docked (the strip makes room) or overlay (floats over the strip).
    static var stickyModeChoice: ActionArgument {
        ActionArgument(name: "mode", title: String(localized: "argument.stickyMode", defaultValue: "Mode", bundle: .module),
                       kind: .enumeration([choice("docked"), choice("overlay")]))
    }

    static var commandString: ActionArgument {
        ActionArgument(name: "command", title: String(localized: "argument.command", defaultValue: "Command", bundle: .module), kind: .string)
    }

    static var pathString: ActionArgument {
        ActionArgument(name: "path", title: String(localized: "argument.path", defaultValue: "Path", bundle: .module), kind: .string)
    }

    static var contentsString: ActionArgument {
        ActionArgument(name: "contents", title: String(localized: "argument.contents", defaultValue: "Contents", bundle: .module), kind: .string)
    }

    static var publicKeyString: ActionArgument {
        ActionArgument(name: "publicKey", title: String(localized: "argument.publicKey", defaultValue: "SSH Public Key", bundle: .module), kind: .string)
    }

    static var appString: ActionArgument {
        ActionArgument(name: "app", title: String(localized: "argument.app", defaultValue: "App", bundle: .module), kind: .string)
    }

    static var themeChoice: ActionArgument {
        ActionArgument(name: "theme", title: String(localized: "argument.theme", defaultValue: "Theme", bundle: .module), kind: .enumeration([choice("system"), choice("light"), choice("dark")]))
    }

    static var snapshotString: ActionArgument {
        ActionArgument(name: "snapshot", title: String(localized: "argument.snapshot", defaultValue: "Snapshot", bundle: .module), kind: .string)
    }

    static var portInt: ActionArgument {
        ActionArgument(name: "port", title: String(localized: "argument.port", defaultValue: "Port", bundle: .module), kind: .int(1...65535))
    }

    static var sizeChoice: ActionArgument {
        ActionArgument(name: "size", title: String(localized: "argument.size", defaultValue: "Size", bundle: .module), kind: .enumeration([choice("small"), choice("medium"), choice("large"), choice("xlarge")]))
    }

    static var settingString: ActionArgument {
        ActionArgument(name: "setting", title: String(localized: "argument.setting", defaultValue: "Setting", bundle: .module), kind: .string)
    }

    static var cwdString: ActionArgument {
        ActionArgument(name: "cwd", title: String(localized: "argument.cwd", defaultValue: "Working Directory", bundle: .module), kind: .string)
    }

    static var envString: ActionArgument {
        ActionArgument(name: "env", title: String(localized: "argument.env", defaultValue: "Environment (JSON)", bundle: .module), kind: .string)
    }

    static var focusBool: ActionArgument {
        ActionArgument(name: "focus", title: String(localized: "argument.focus", defaultValue: "Focus", bundle: .module), kind: .bool)
    }

    static var keepBool: ActionArgument {
        ActionArgument(name: "keep", title: String(localized: "argument.keep", defaultValue: "Keep After Close", bundle: .module), kind: .bool)
    }

    static var onBool: ActionArgument {
        ActionArgument(name: "on", title: String(localized: "argument.on", defaultValue: "On", bundle: .module), kind: .bool)
    }

    /// Base keymap presets (`ShortcutKeymapPreset` raw values).
    static var keymapChoice: ActionArgument {
        ActionArgument(name: "keymap", title: String(localized: "argument.keymap", defaultValue: "Keymap", bundle: .module), kind: .enumeration([
            ActionEnumCase(value: "cmux", title: String(localized: "argument.value.keymap.cmux", defaultValue: "cmux (Default)", bundle: .module)),
            ActionEnumCase(value: "iterm2", title: String(localized: "argument.value.keymap.iterm2", defaultValue: "iTerm2", bundle: .module)),
            ActionEnumCase(value: "terminal", title: String(localized: "argument.value.keymap.terminal", defaultValue: "Terminal.app", bundle: .module)),
            ActionEnumCase(value: "tmux", title: String(localized: "argument.value.keymap.tmux", defaultValue: "Prefix chords (Ctrl-B)", bundle: .module)),
        ]))
    }

    static var channelChoice: ActionArgument {
        ActionArgument(name: "channel", title: String(localized: "argument.channel", defaultValue: "Channel", bundle: .module), kind: .enumeration([choice("stable"), choice("nightly")]))
    }

    static var topicString: ActionArgument {
        ActionArgument(name: "topic", title: String(localized: "argument.topic", defaultValue: "Topic", bundle: .module), kind: .string)
    }

    /// Optional page to open (`openBrowser`).
    /// Optional search text (`tab.search`): the page opens with it typed.
    static var queryString: ActionArgument {
        ActionArgument(name: "query", title: String(localized: "argument.query", defaultValue: "Search", bundle: .module), kind: .string,
                       isRequired: false)
    }

    static var urlString: ActionArgument {
        ActionArgument(name: "url", title: String(localized: "argument.url", defaultValue: "URL", bundle: .module), kind: .string, isRequired: false)
    }

    /// Optional browser engine (`openBrowser`). Without it the tab uses
    /// `browser.defaultEngine` (Chromium unless set to WebKit).
    static var engineChoice: ActionArgument {
        ActionArgument(name: "engine", title: String(localized: "argument.engine", defaultValue: "Engine", bundle: .module),
                       kind: .enumeration([choice("webkit"), choice("cef")]), isRequired: false)
    }

    /// Optional `confirm` flag every destructive action takes.
    static var confirmBool: ActionArgument {
        ActionArgument(name: ActionArgument.confirmName, title: String(localized: "argument.confirm", defaultValue: "Confirm", bundle: .module),
                       kind: .bool, isRequired: false)
    }

    private static func choice(_ value: String) -> ActionEnumCase {
        ActionEnumCase(value: value, title: choiceTitle(value))
    }

    private static func choiceTitle(_ value: String) -> String {
        switch value {
        case "grey": String(localized: "argument.value.grey", defaultValue: "Grey", bundle: .module)
        case "docked": String(localized: "argument.value.docked", defaultValue: "Docked", bundle: .module)
        case "overlay": String(localized: "argument.value.overlay", defaultValue: "Overlay", bundle: .module)
        case "blue": String(localized: "argument.value.blue", defaultValue: "Blue", bundle: .module)
        case "red": String(localized: "argument.value.red", defaultValue: "Red", bundle: .module)
        case "yellow": String(localized: "argument.value.yellow", defaultValue: "Yellow", bundle: .module)
        case "green": String(localized: "argument.value.green", defaultValue: "Green", bundle: .module)
        case "pink": String(localized: "argument.value.pink", defaultValue: "Pink", bundle: .module)
        case "purple": String(localized: "argument.value.purple", defaultValue: "Purple", bundle: .module)
        case "cyan": String(localized: "argument.value.cyan", defaultValue: "Cyan", bundle: .module)
        case "orange": String(localized: "argument.value.orange", defaultValue: "Orange", bundle: .module)
        case "webkit": String(localized: "argument.value.webkit", defaultValue: "WebKit", bundle: .module)
        case "cef": String(localized: "argument.value.cef", defaultValue: "Chromium", bundle: .module)
        case "auto": String(localized: "argument.value.auto", defaultValue: "Automatic", bundle: .module)
        case "todo": String(localized: "argument.value.todo", defaultValue: "To Do", bundle: .module)
        case "inProgress": String(localized: "argument.value.inProgress", defaultValue: "In Progress", bundle: .module)
        case "review": String(localized: "argument.value.review", defaultValue: "In Review", bundle: .module)
        case "done": String(localized: "argument.value.done", defaultValue: "Done", bundle: .module)
        case "blocked": String(localized: "argument.value.blocked", defaultValue: "Blocked", bundle: .module)
        case "system": String(localized: "argument.value.system", defaultValue: "System", bundle: .module)
        case "light": String(localized: "argument.value.light", defaultValue: "Light", bundle: .module)
        case "dark": String(localized: "argument.value.dark", defaultValue: "Dark", bundle: .module)
        case "small": String(localized: "argument.value.small", defaultValue: "Small", bundle: .module)
        case "medium": String(localized: "argument.value.medium", defaultValue: "Medium", bundle: .module)
        case "large": String(localized: "argument.value.large", defaultValue: "Large", bundle: .module)
        case "xlarge": String(localized: "argument.value.xlarge", defaultValue: "Extra Large", bundle: .module)
        case "stable": String(localized: "argument.value.stable", defaultValue: "Stable", bundle: .module)
        case "nightly": String(localized: "argument.value.nightly", defaultValue: "Nightly", bundle: .module)
        case "right": String(localized: "argument.value.right", defaultValue: "Right", bundle: .module)
        case "down": String(localized: "argument.value.down", defaultValue: "Down", bundle: .module)
        case "left": String(localized: "argument.value.left", defaultValue: "Left", bundle: .module)
        case "up": String(localized: "argument.value.up", defaultValue: "Up", bundle: .module)
        default: value
        }
    }
}
