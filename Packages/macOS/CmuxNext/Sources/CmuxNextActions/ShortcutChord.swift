public import AppKit

/// A two-key shortcut (`["ctrl+b", "c"]` in cmux.json), as the old app's
/// Prefix-chord bindings: the first key arms it, the next key runs the action.
/// The first key needs Command or Control, since only those reach the key
/// router; the second may be a plain key.
public nonisolated struct ShortcutChord: Hashable, Sendable {
    public let first: Shortcut
    public let second: Shortcut

    public init(_ first: Shortcut, _ second: Shortcut) {
        self.first = first
        self.second = second
    }

    @MainActor public var keycaps: [String] { first.keycaps + second.keycaps }
}

extension ActionRegistry {
    /// `id`'s chord from cmux.json, or nil. A chord replaces the action's
    /// single-key shortcut, so ``effectiveShortcut(for:)`` is nil then.
    public func effectiveChord(for id: ActionID) -> ShortcutChord? {
        chordOverrides[canonicalID(for: id)]
    }

    /// Sets a chord override (replacing any single-key override).
    public func setChordOverride(_ chord: ShortcutChord, for id: ActionID) {
        let id = canonicalID(for: id)
        shortcutOverrides.removeValue(forKey: id)
        chordOverrides[id] = chord
    }

    /// Whether `shortcut` starts a chord whose action could run now.
    public func startsChord(_ shortcut: Shortcut) -> Bool {
        let index = currentShortcutIndex()
        let seconds = Array((index.chords[shortcut] ?? [:]).values) + Array((index.chordDigitFamilies[shortcut] ?? [:]).values)
        return seconds.joined().contains { canPerform($0) }
    }

    /// The action the second key of a chord started by `prefix` runs, plus
    /// the digit for a numbered family (`ctrl+b` then `3`).
    public func resolveChord(after prefix: Shortcut, _ second: Shortcut) -> (id: ActionID, argument: String?)? {
        let index = currentShortcutIndex()
        if let id = bestCandidate(index.chords[prefix]?[second] ?? []) { return (id, nil) }
        if second.key.count == 1, let digit = second.key.first, ("1"..."9").contains(digit),
           let id = bestCandidate(index.chordDigitFamilies[prefix]?[Shortcut("1", modifiers: second.modifiers)] ?? []) {
            return (id, String(digit))
        }
        return nil
    }

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

    /// The shortcuts a key-down may mean: its characters, then the unshifted
    /// key ("}" or "]" for Shift-]), with its modifiers.
    static func shortcuts(for event: NSEvent) -> [Shortcut] {
        guard event.type == .keyDown else { return [] }
        let flags = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        var keys: [String] = []
        if let key = event.charactersIgnoringModifiers?.lowercased() { keys.append(key) }
        if let base = event.characters(byApplyingModifiers: [])?.lowercased(), !keys.contains(base) { keys.append(base) }
        return keys.map { Shortcut($0, modifiers: flags) }
    }
}
