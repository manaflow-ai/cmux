#if canImport(AppKit)
public import AppKit

/// The NSEvent edge of ``KeyModifiers`` and ``Shortcut`` (Chromium's ui/events/cocoa/cocoa_event_utils.mm
/// role): a key-down becomes the values the binding table matches, and a shortcut becomes a menu's mask.
extension KeyModifiers {
    /// The shortcut modifiers among an event's flags (caps lock, fn and numeric pad dropped).
    public nonisolated init(eventFlags: NSEvent.ModifierFlags) {
        self = KeyModifiers(rawValue: eventFlags.rawValue).intersection(.relevant)
    }

    /// The same modifiers as AppKit flags, for `NSMenuItem.keyEquivalentModifierMask` and synthesized events.
    public nonisolated var eventFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: rawValue)
    }
}

extension Shortcut {
    /// Whether a key-down event triggers this shortcut.
    public nonisolated func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, KeyModifiers(eventFlags: event.modifierFlags) == modifiers else { return false }
        // `charactersIgnoringModifiers` keeps shift applied for letters on
        // some layouts, so compare lowercased.
        return event.charactersIgnoringModifiers?.lowercased() == key
    }
}

extension ActionRegistry {
    /// The first key of a chord a key-down starts, or nil.
    public func chordPrefix(for event: NSEvent) -> Shortcut? {
        Self.shortcuts(for: event).first(where: startsChord)
    }

    /// The action a key-down completes after `prefix`, with its tier.
    public func resolveChord(after prefix: Shortcut, event: NSEvent) -> (id: ActionID, argument: String?, tier: ActionKeyTier)? {
        guard event.type == .keyDown else { return nil }
        for shortcut in Self.shortcuts(for: event) {
            if let resolved = resolveChord(after: prefix, shortcut) {
                return (resolved.id, resolved.argument, keyTier(for: resolved.id))
            }
        }
        return nil
    }

    /// The action a key-down resolves to in the current context, with its tier, without running it
    /// (``resolveShortcut(readings:)``).
    public func resolveShortcut(for event: NSEvent) -> (id: ActionID, argument: String?, tier: ActionKeyTier)? {
        resolveShortcut(readings: Self.shortcuts(for: event))
    }

    /// The shortcuts a key-down may mean: its characters, then the unshifted
    /// key ("}" or "]" for Shift-]), with its modifiers.
    public static func shortcuts(for event: NSEvent) -> ShortcutReadings {
        guard event.type == .keyDown else { return ShortcutReadings() }
        let flags = KeyModifiers(eventFlags: event.modifierFlags)
        let key = event.charactersIgnoringModifiers.map { Shortcut($0, modifiers: flags) }
        let base = event.characters(byApplyingModifiers: []).map { Shortcut($0, modifiers: flags) }
        switch (key, base) {
        case (let key?, let base?): return ShortcutReadings(key, base)
        case (let only?, nil), (nil, let only?): return ShortcutReadings(only)
        case (nil, nil): return ShortcutReadings()
        }
    }
}
#endif
