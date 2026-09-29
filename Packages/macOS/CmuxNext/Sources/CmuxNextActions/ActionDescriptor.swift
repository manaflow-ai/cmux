import AppKit

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
