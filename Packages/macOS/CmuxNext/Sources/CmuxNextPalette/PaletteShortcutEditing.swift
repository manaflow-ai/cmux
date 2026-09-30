public import AppKit
public import CmuxNextActions

/// What the shortcut recorder needs from the App: the chord's other
/// meanings, and writing `shortcuts.bindings` in cmux.json (the file
/// watcher then applies it to every window).
@MainActor public protocol PaletteShortcutEditing: AnyObject {
    /// Ghostty keybinds and Chrome chords for the key-down being recorded
    /// (nil for a restored default).
    func environment(for event: NSEvent?) -> ShortcutEditEnvironment
    /// Writes each shortcut; nil unbinds the action (`null`).
    func save(_ changes: [ShortcutChange])
    /// Removes `id`'s override, restoring its default, and unbinds `others`.
    func restoreDefault(_ id: ActionID, unbinding others: [ActionID])
}

public struct ShortcutChange: Equatable, Sendable {
    public var id: ActionID
    public var shortcut: Shortcut?

    public init(_ id: ActionID, _ shortcut: Shortcut?) {
        self.id = id
        self.shortcut = shortcut
    }
}

/// A choice the recorder offers (click, or its key).
public enum PaletteShortcutOption: Equatable, Sendable {
    case save, replace, keepBoth, cancel, remove, restoreDefault
}
