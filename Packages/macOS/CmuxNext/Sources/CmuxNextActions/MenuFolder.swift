/// A titled submenu that collects the less used rows of a right-click menu
/// ("Move ▸", "Copy ▸"). A placement names its folder; the menu shows the
/// folder as one row after its group's rows, in declaration order. A folder with one row in a
/// menu shows that row inline instead.
public nonisolated enum MenuFolder: String, CaseIterable, Sendable, Hashable {
    case new
    case split
    case agent
    case openIn
    case appearance
    case options
    case group
    case move
    case layout
    case connection
    case copy
    case tools
    case close

    /// Where the folder row sits in its menu.
    public var group: MenuGroup {
        switch self {
        case .new, .split, .agent: .create
        case .openIn: .reopen
        case .appearance, .options: .identity
        case .group: .organize
        case .move: .move
        case .layout: .layout
        case .connection: .connection
        case .copy, .tools: .inspect
        case .close: .close
        }
    }

    /// Localized submenu title.
    public var title: String {
        switch self {
        case .new: String(localized: "menu.folder.new", defaultValue: "New", bundle: .module)
        case .split: String(localized: "menu.folder.split", defaultValue: "Split", bundle: .module)
        case .agent: String(localized: "menu.folder.agent", defaultValue: "Agent", bundle: .module)
        case .openIn: String(localized: "menu.folder.openIn", defaultValue: "Open In", bundle: .module)
        case .appearance: String(localized: "menu.folder.appearance", defaultValue: "Appearance", bundle: .module)
        case .options: String(localized: "menu.folder.options", defaultValue: "Options", bundle: .module)
        case .group: String(localized: "menu.folder.group", defaultValue: "Group", bundle: .module)
        case .move: String(localized: "menu.folder.move", defaultValue: "Move", bundle: .module)
        case .layout: String(localized: "menu.folder.layout", defaultValue: "Layout", bundle: .module)
        case .connection: String(localized: "menu.folder.connection", defaultValue: "Connection", bundle: .module)
        case .copy: String(localized: "menu.folder.copy", defaultValue: "Copy", bundle: .module)
        case .tools: String(localized: "menu.folder.tools", defaultValue: "Tools", bundle: .module)
        case .close: String(localized: "menu.folder.close", defaultValue: "Close", bundle: .module)
        }
    }
}
