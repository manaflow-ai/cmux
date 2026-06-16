/// A keyboard shortcut decoded from a Ghostty key trigger.
///
/// Carries exactly the fields the app target feeds into its `StoredShortcut`
/// initializer from the Ghostty goto-split path: a lowercased key string and the
/// four modifier flags. The app maps this value onto its own `StoredShortcut` at
/// the call seam.
public struct GhosttyTriggerShortcut: Sendable, Equatable, Hashable {
    /// The key glyph or lowercased character for the shortcut.
    public var key: String
    /// Whether the Command modifier is part of the shortcut.
    public var command: Bool
    /// Whether the Shift modifier is part of the shortcut.
    public var shift: Bool
    /// Whether the Option modifier is part of the shortcut.
    public var option: Bool
    /// Whether the Control modifier is part of the shortcut.
    public var control: Bool

    /// Creates a decoded shortcut.
    /// - Parameters:
    ///   - key: The key glyph or lowercased character.
    ///   - command: Whether Command is held.
    ///   - shift: Whether Shift is held.
    ///   - option: Whether Option is held.
    ///   - control: Whether Control is held.
    public init(key: String, command: Bool, shift: Bool, option: Bool, control: Bool) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }
}
