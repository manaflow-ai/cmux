public import AppKit

/// The Cmd-J leader over a registry: Cmd-J arms it, the next single key
/// runs an action, and a which-key overlay lists those keys while it waits
/// (the App's `ChordTracker` and `WhichKeyController`). Its bindings are
/// ordinary chords whose first key is `prefix`, so cmux.json rebinds each
/// one like any chord (`["cmd+j", "k"]`), and unbinding them all gives
/// Cmd-J back to the focused view. Ghostty's own `super+j` is unbound for
/// it (`GhosttyRuntime.cmuxDefaultKeybindLines`).
public struct LeaderLayer {
    public nonisolated static let prefix = Shortcut("j", modifiers: [.command])

    /// The second key of each default leader chord, by action
    /// (`ActionDescriptor.defaultChord`, set by the catalog).
    public nonisolated static let defaultChords: [(id: ActionID, key: Shortcut)] = [
        // Ghostty's macOS default for it was Cmd-J itself.
        ("terminal.scrollToSelection", Shortcut("j", modifiers: [])),
        ("palette.newAgentChat", Shortcut("s", modifiers: [])),
        // `?` on a US layout; cmux.json writes it `shift+/`.
        ("palette.searchShortcuts", Shortcut("/", modifiers: [.shift])),
    ]

    let registry: ActionRegistry

    public init(registry: ActionRegistry) {
        self.registry = registry
    }

    /// The first key of a chord a key-down arms: one whose action could run
    /// now, else the leader when some binding sits under it, even one that
    /// cannot run in this focus, so the overlay says what Cmd-J offers.
    /// Reads the event's keys once.
    public func chordPrefix(for event: NSEvent) -> Shortcut? {
        let shortcuts = ActionRegistry.shortcuts(for: event)
        if let first = shortcuts.first(where: registry.startsChord) { return first }
        return shortcuts.contains(Self.prefix) && hasChords(after: Self.prefix) ? Self.prefix : nil
    }

    /// Every binding under `prefix` (the which-key overlay), whether or not
    /// its action can run now; numbered families keyed by their `1`.
    public func chords(after prefix: Shortcut = Self.prefix) -> [ChordBinding] {
        let index = registry.currentShortcutIndex()
        return [index.chords[prefix], index.chordDigitFamilies[prefix]].compactMap { $0 }.flatMap { table in
            table.flatMap { second, ids in ids.map { ChordBinding(second: second, id: $0) } }
        }
    }

    /// Whether any binding sits under `prefix`.
    public func hasChords(after prefix: Shortcut = Self.prefix) -> Bool {
        let index = registry.currentShortcutIndex()
        return index.chords[prefix]?.isEmpty == false || index.chordDigitFamilies[prefix]?.isEmpty == false
    }

    /// A default chord to show as `id`'s shortcut, when no single key or
    /// label shows instead: Scroll to Selection reads `⌘J J`, New Agent
    /// Chat keeps `⇧⌘I`.
    func shownDefaultChord(for id: ActionID) -> ShortcutChord? {
        guard registry.descriptor(for: id)?.shortcutLabel == nil, registry.effectiveShortcut(for: id) == nil else { return nil }
        return registry.effectiveChord(for: id)
    }

    /// The catalog's `defaultChord` for canonical `id`, unless cmux.json
    /// gives `id` a single key or unbinds it, or binds some action's single
    /// key to the chord's first key: a user's own `cmd+j` wins over the
    /// leader defaults.
    func defaultChord(for id: ActionID) -> ShortcutChord? {
        guard registry.shortcutOverrides[id] == nil, let chord = registry.descriptor(for: id)?.defaultChord,
              !registry.shortcutOverrides.values.contains(.some(chord.first)) else { return nil }
        return chord
    }
}

extension [ActionDescriptor] {
    /// The catalog with `defaultChord` set on the rows
    /// `LeaderLayer.defaultChords` names.
    nonisolated func withLeaderChords() -> [ActionDescriptor] {
        var keys: [ActionID: Shortcut] = [:]
        for (id, key) in LeaderLayer.defaultChords { keys[id] = key }
        return map { descriptor in
            guard let key = keys[descriptor.id] else { return descriptor }
            var descriptor = descriptor
            descriptor.defaultChord = ShortcutChord(LeaderLayer.prefix, key)
            return descriptor
        }
    }
}
