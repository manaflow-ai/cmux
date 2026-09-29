public import AppKit

/// Stable identifier for an action, e.g. `view.toggleSidebar`.
///
/// IDs are the contract shared by the palette, menus, shortcuts, the settings
/// file, and the debug socket, so never rename one without a migration.
public struct ActionID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

/// A key equivalent plus modifiers. `key` uses NSMenuItem key-equivalent
/// semantics: a lowercase character, or a function-key character.
public struct Shortcut: Hashable, Sendable {
    public let key: String
    public let modifiers: NSEvent.ModifierFlags

    public init(_ key: String, modifiers: NSEvent.ModifierFlags = [.command]) {
        self.key = key.lowercased()
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
    }

    /// Modifiers that participate in matching; caps lock, fn, and numeric pad
    /// flags are ignored.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// Whether a key-down event triggers this shortcut.
    public func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(Self.relevantModifiers)
        guard flags == modifiers else { return false }
        // `charactersIgnoringModifiers` keeps shift applied for letters on
        // some layouts, so compare lowercased.
        return event.charactersIgnoringModifiers?.lowercased() == key
    }

    // `NSEvent.ModifierFlags` is not Hashable; hash its raw value.
    public static func == (lhs: Shortcut, rhs: Shortcut) -> Bool {
        lhs.key == rhs.key && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }
}

/// One user-invocable command. Every entrypoint (palette, menu, shortcut,
/// debug socket) resolves to the same `handler`.
public struct Action: Identifiable {
    public let id: ActionID
    public var title: String
    public var keywords: [String]
    public var shortcut: Shortcut?
    public var isEnabled: @MainActor () -> Bool
    public var handler: @MainActor () -> Void
    /// Handler for argument-taking actions: the text typed into the palette's
    /// inline entry, the item picked from a nested list, or the digit of a
    /// numbered shortcut family. Nil means the action takes no argument and
    /// `handler` runs instead.
    public var argumentHandler: (@MainActor (String) -> Void)?

    public init(
        id: ActionID,
        title: String,
        keywords: [String] = [],
        shortcut: Shortcut? = nil,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        argumentHandler: (@MainActor (String) -> Void)? = nil,
        handler: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.argumentHandler = argumentHandler
        self.handler = handler
    }

    /// A copy of this action under another ID (used to fold legacy IDs into
    /// their canonical catalog ID).
    func withID(_ newID: ActionID) -> Action {
        Action(
            id: newID,
            title: title,
            keywords: keywords,
            shortcut: shortcut,
            isEnabled: isEnabled,
            argumentHandler: argumentHandler,
            handler: handler
        )
    }
}
