import AppKit

/// Functional domain of an action. Matches the sections of the action catalog
/// in plans/cmux-next/inventory.md section 1.
public enum ActionCategory: String, CaseIterable, Sendable, Hashable {
    case window
    case workspace
    case pane
    case tab
    case terminal
    case browser
    case sidebar
    case notifications
    case agents
    case cloud
    case settings
    /// Actions registered at runtime without a catalog descriptor.
    case other

    /// Localized section title.
    public var title: String {
        switch self {
        case .window: String(localized: "category.window", defaultValue: "Window", bundle: .module)
        case .workspace: String(localized: "category.workspace", defaultValue: "Workspace", bundle: .module)
        case .pane: String(localized: "category.pane", defaultValue: "Panes", bundle: .module)
        case .tab: String(localized: "category.tab", defaultValue: "Tabs", bundle: .module)
        case .terminal: String(localized: "category.terminal", defaultValue: "Terminal", bundle: .module)
        case .browser: String(localized: "category.browser", defaultValue: "Browser and Viewers", bundle: .module)
        case .sidebar: String(localized: "category.sidebar", defaultValue: "Sidebar", bundle: .module)
        case .notifications: String(localized: "category.notifications", defaultValue: "Notifications", bundle: .module)
        case .agents: String(localized: "category.agents", defaultValue: "Agents", bundle: .module)
        case .cloud: String(localized: "category.cloud", defaultValue: "Cloud and Account", bundle: .module)
        case .settings: String(localized: "category.settings", defaultValue: "Settings and Help", bundle: .module)
        case .other: String(localized: "category.other", defaultValue: "Other", bundle: .module)
        }
    }

    /// Display order of category sections.
    public var sortOrder: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

/// Surfaces where the old app exposed an action (inventory legend P/K/M/C).
/// Informational: menus and context menus in cmux-next are built by the App.
public struct ActionSurfaces: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let palette = ActionSurfaces(rawValue: 1 << 0)
    public static let keyboard = ActionSurfaces(rawValue: 1 << 1)
    public static let menu = ActionSurfaces(rawValue: 1 << 2)
    public static let contextMenu = ActionSurfaces(rawValue: 1 << 3)
}

/// Focus and session facts the App publishes to the registry. A descriptor's
/// `requires` must be a subset of the current context for the action to be
/// available, which is also how conflicting default shortcuts (for example
/// Cmd-[ for focus history and browser back) resolve.
public struct ActionContext: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let terminalFocused = ActionContext(rawValue: 1 << 0)
    public static let browserFocused = ActionContext(rawValue: 1 << 1)
    public static let canvasLayout = ActionContext(rawValue: 1 << 2)
    public static let simulatorFocused = ActionContext(rawValue: 1 << 3)
    public static let diffViewerFocused = ActionContext(rawValue: 1 << 4)
    public static let filePreviewFocused = ActionContext(rawValue: 1 << 5)
    public static let markdownFocused = ActionContext(rawValue: 1 << 6)
    public static let rightSidebarFocused = ActionContext(rawValue: 1 << 7)
    public static let fileExplorerFocused = ActionContext(rawValue: 1 << 8)
    public static let textBoxFocused = ActionContext(rawValue: 1 << 9)
    public static let paletteOpen = ActionContext(rawValue: 1 << 10)
    public static let signedIn = ActionContext(rawValue: 1 << 11)
    public static let signedOut = ActionContext(rawValue: 1 << 12)
    public static let cloudWorkspace = ActionContext(rawValue: 1 << 13)
}

/// What an action needs from the user before it runs. The palette turns
/// `.text` into inline text entry and `.list` into a nested list.
public enum ActionInput: Sendable, Hashable {
    case none
    case text
    case list
}

/// A shortcut that stands for a numbered family, such as Cmd-1 to Cmd-9.
public enum ShortcutFamily: Sendable, Hashable {
    /// The digit keys 1 to 9 with the descriptor's modifiers. The pressed
    /// digit is passed to the action's argument handler.
    case digits
}

/// Declarative description of one user-invocable action. The catalog holds
/// every descriptor; the App binds handlers by ID later. Menus, the key
/// router, the palette, and the shortcut settings all read shortcuts from
/// the registry, which starts from `defaultShortcut`.
public struct ActionDescriptor: Identifiable, Sendable {
    public let id: ActionID
    public var title: String
    public var keywords: [String]
    public var defaultShortcut: Shortcut?
    /// Display text for shortcuts a `Shortcut` cannot express, such as the
    /// vim sequence `g g`. Takes precedence over the formatted shortcut.
    public var shortcutLabel: String?
    public var shortcutFamily: ShortcutFamily?
    public var category: ActionCategory
    /// SF Symbol name.
    public var symbol: String
    public var surfaces: ActionSurfaces
    public var requires: ActionContext
    public var input: ActionInput
    public var isDebugOnly: Bool

    public init(
        id: ActionID,
        title: String,
        keywords: [String] = [],
        defaultShortcut: Shortcut? = nil,
        shortcutLabel: String? = nil,
        shortcutFamily: ShortcutFamily? = nil,
        category: ActionCategory,
        symbol: String = "command",
        surfaces: ActionSurfaces = [.palette],
        requires: ActionContext = [],
        input: ActionInput = .none,
        isDebugOnly: Bool = false
    ) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.defaultShortcut = defaultShortcut
        self.shortcutLabel = shortcutLabel
        self.shortcutFamily = shortcutFamily
        self.category = category
        self.symbol = symbol
        self.surfaces = surfaces
        self.requires = requires
        self.input = input
        self.isDebugOnly = isDebugOnly
    }
}
