public import AppKit

/// The user's Toggle Developer Tools shortcut, shown on the dock menu's Close Developer Tools row
/// so the menu teaches the toggle. The app reads it from its shortcut settings.
public struct BrowserDevToolsMenuShortcut: Hashable, Sendable {
    /// The menu item key equivalent, e.g. `"i"`.
    public var key: String
    /// The modifiers, e.g. `[.command, .option]`.
    public var modifiers: NSEvent.ModifierFlags

    /// Creates a shortcut.
    /// - Parameters:
    ///   - key: The menu item key equivalent.
    ///   - modifiers: The modifiers.
    public init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }
}
