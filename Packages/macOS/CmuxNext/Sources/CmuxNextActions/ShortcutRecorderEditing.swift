public import AppKit

/// What the shortcut recorder needs from the App: the chord's other
/// meanings, and writing `shortcuts.bindings` in cmux.json (the file
/// watcher then applies it to every window, the palette and Settings).
@MainActor public protocol ShortcutRecorderEditing: AnyObject {
    /// Ghostty keybinds and browser chords for the key-down being recorded
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
