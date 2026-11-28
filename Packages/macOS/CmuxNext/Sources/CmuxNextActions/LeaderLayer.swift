public import AppKit

/// The Cmd-J leader over a registry: Cmd-J arms it, the next single key
/// runs an action, and a which-key overlay lists those keys while it waits
/// (the App's `ChordTracker`, CmuxNextFocusUI's `WhichKeyController`). Its bindings are
/// ordinary chords whose first key is `prefix`, so cmux.json rebinds each
/// one like any chord (`["cmd+j", "k"]`), and unbinding them all gives
/// Cmd-J back to the focused view. Ghostty's own `super+j` is unbound for
/// it (`GhosttyRuntime.cmuxDefaultKeybindLines`).
public struct LeaderLayer {
    public nonisolated static let prefix = Shortcut("j", modifiers: [.command])

    let registry: ActionRegistry

    public init(registry: ActionRegistry) {
        self.registry = registry
    }

    /// Every binding under `prefix` (the which-key overlay), whether or not
    /// its action can run now; numbered families keyed by their `1`.
    public func chords(after prefix: Shortcut = Self.prefix) -> [ChordBinding] {
        let index = registry.currentShortcutIndex()
        return [index.chords[prefix], index.chordDigitFamilies[prefix]].compactMap { $0 }.flatMap { table in
            table.flatMap { second, ids in ids.map { ChordBinding(second: second, id: $0) } }
        }
    }

    /// Whether a key that ended an armed chord without completing it is decided as a shortcut of its own (the key
    /// router then routes it as usual): a Command or Control chord bound to a system or navigation action, other
    /// than the leader prefix itself (a second Cmd-J still dismisses the leader). Content shortcuts and typing keep
    /// going to the view.
    ///
    /// - Parameters:
    ///   - event: The key-down that ended the chord.
    ///   - resolved: What the key resolves to in the current context (``ActionRegistry/resolveShortcut(for:)``).
    ///   - qwerty: `app.shortcutLayout` is Keep QWERTY Positions (``ActionRegistry/matchesQwertyPositions``).
    public static func decidesAfterChord(_ event: NSEvent, resolved: (id: ActionID, argument: String?, tier: ActionKeyTier)?, qwerty: Bool) -> Bool {
        guard !event.modifierFlags.isDisjoint(with: [.command, .control]), let resolved, resolved.tier != .content else { return false }
        return !ActionRegistry.shortcuts(for: event, qwerty: qwerty).contains(prefix)
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
              !registry.shortcutOverrides.values.contains(.some(chord.first)),
              !registry.alternateShortcuts.values.contains(where: { $0.contains([chord.first]) }) else { return nil }
        return chord
    }
}
