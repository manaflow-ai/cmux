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
    /// Sort orders (the sidebar's Sort ▸).
    case sort
    case layout
    case connection
    case copy
    case tools
    case close
    /// Bulk archive rows (Archive Others, Below, Above), after Close's rows.
    case archive
    /// Every row a crowded menu keeps off its top level (`ContextMenuEssentials`).
    case more

    /// Where the folder row sits in its menu.
    public var group: MenuGroup {
        switch self {
        case .new, .split, .agent: .create
        case .openIn: .reopen
        case .appearance, .options: .identity
        case .group: .organize
        case .move, .sort: .move
        case .layout: .layout
        case .connection: .connection
        case .copy, .tools: .inspect
        case .close, .archive, .more: .close
        }
    }

    /// The folder row's icon (an SF Symbol), beside its rows' own icons.
    public var symbol: String {
        switch self {
        case .new: "plus.square"
        case .split: "rectangle.split.2x1"
        case .agent: "sparkles"
        case .openIn: "arrow.up.forward.app"
        case .appearance: "paintpalette"
        case .options: "slider.horizontal.3"
        case .group: "square.stack.3d.up"
        case .move: "arrow.up.and.down.square"
        case .sort: "arrow.up.arrow.down"
        case .layout: "rectangle.3.group"
        case .connection: "network"
        case .copy: "doc.on.doc"
        case .tools: "wrench.and.screwdriver"
        case .close: "xmark.square"
        case .archive: "archivebox"
        case .more: "ellipsis.circle"
        }
    }

    /// Localized submenu title.
    public var title: String {
        switch self {
        case .new: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.new") + "\u{E002}" + String(localized: "menu.folder.new", defaultValue: "New", bundle: .module))
        case .split: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.split") + "\u{E002}" + String(localized: "menu.folder.split", defaultValue: "Split", bundle: .module))
        case .agent: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.agent") + "\u{E002}" + String(localized: "menu.folder.agent", defaultValue: "Agent", bundle: .module))
        case .openIn: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.openIn") + "\u{E002}" + String(localized: "menu.folder.openIn", defaultValue: "Open In", bundle: .module))
        case .appearance: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.appearance") + "\u{E002}" + String(localized: "menu.folder.appearance", defaultValue: "Appearance", bundle: .module))
        case .options: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.options") + "\u{E002}" + String(localized: "menu.folder.options", defaultValue: "Options", bundle: .module))
        case .group: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.group") + "\u{E002}" + String(localized: "menu.folder.group", defaultValue: "Group", bundle: .module))
        case .move: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.move") + "\u{E002}" + String(localized: "menu.folder.move", defaultValue: "Move", bundle: .module))
        case .sort: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.sort") + "\u{E002}" + String(localized: "menu.folder.sort", defaultValue: "Sort", bundle: .module))
        case .layout: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.layout") + "\u{E002}" + String(localized: "menu.folder.layout", defaultValue: "Layout", bundle: .module))
        case .connection: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.connection") + "\u{E002}" + String(localized: "menu.folder.connection", defaultValue: "Connection", bundle: .module))
        case .copy: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.copy") + "\u{E002}" + String(localized: "menu.folder.copy", defaultValue: "Copy", bundle: .module))
        case .tools: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.tools") + "\u{E002}" + String(localized: "menu.folder.tools", defaultValue: "Tools", bundle: .module))
        case .close: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.close") + "\u{E002}" + String(localized: "menu.folder.close", defaultValue: "Close", bundle: .module))
        case .archive: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.archive") + "\u{E002}" + String(localized: "menu.folder.archive", defaultValue: "Archive", bundle: .module))
        case .more: ("\u{E000}Localizable\u{E001}" + String(describing: "menu.folder.more") + "\u{E002}" + String(localized: "menu.folder.more", defaultValue: "More", bundle: .module))
        }
    }
}
