public import AppKit

/// The Cmd-J leader: Cmd-J arms it, the next single key runs an action,
/// and a which-key overlay lists those keys while it waits (the App's
/// `ChordTracker` and `WhichKeyController`). Its bindings are ordinary
/// chords whose first key is `prefix`, so cmux.json rebinds each one like
/// any chord (`["cmd+j", "k"]`), and unbinding them all gives Cmd-J back to
/// the focused view. Ghostty's own `super+j` is unbound for it
/// (`GhosttyRuntime.cmuxDefaultKeybindLines`).
public nonisolated enum LeaderLayer {
    public static let prefix = Shortcut("j", modifiers: [.command])

    /// The second key of each default leader chord, by action.
    public static let defaultChords: [(id: ActionID, key: Shortcut)] = [
        // Ghostty's macOS default for it was Cmd-J itself.
        ("terminal.scrollToSelection", Shortcut("j", modifiers: [])),
        ("palette.newAgentChat", Shortcut("s", modifiers: [])),
        // `?` on a US layout; cmux.json writes it `shift+/`.
        ("palette.searchShortcuts", Shortcut("/", modifiers: [.shift])),
    ]

    /// Sets `defaultChord` on the catalog rows `defaultChords` names.
    static func apply(to descriptors: [ActionDescriptor]) -> [ActionDescriptor] {
        var keys: [ActionID: Shortcut] = [:]
        for (id, key) in defaultChords { keys[id] = key }
        return descriptors.map { descriptor in
            guard let key = keys[descriptor.id] else { return descriptor }
            var descriptor = descriptor
            descriptor.defaultChord = ShortcutChord(prefix, key)
            return descriptor
        }
    }

    /// The first key of a chord a key-down arms: one whose action could run
    /// now, else the leader when some binding sits under it, even one that
    /// cannot run in this focus, so the overlay says what Cmd-J offers.
    /// Reads the event's keys once.
    @MainActor public static func chordPrefix(for event: NSEvent, in registry: ActionRegistry) -> Shortcut? {
        let shortcuts = ActionRegistry.shortcuts(for: event)
        if let first = shortcuts.first(where: registry.startsChord) { return first }
        return shortcuts.contains(prefix) && registry.hasChords(after: prefix) ? prefix : nil
    }
}
