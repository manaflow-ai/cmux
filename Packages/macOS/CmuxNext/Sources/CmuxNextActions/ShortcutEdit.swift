public import AppKit

/// Why a chord cannot become an action's shortcut.
public enum ShortcutRefusal: Equatable, Sendable {
    /// Neither Command nor Control: the key router only takes Command or
    /// Control chords, so typing, Option characters and IME input pass.
    case needsModifier
    /// macOS keeps it (Spotlight, screenshots, app switcher, ...).
    case reservedByMacOS(name: String)
    /// A tier 0 (system) action owns it; those always run and are not
    /// taken over from the recorder.
    case systemAction(ActionID)
    /// Part of a numbered family (Cmd-1…9) of another action in the same
    /// context.
    case numberedFamily(ActionID)
    /// The action is itself a numbered family, edited in cmux.json.
    case editsNumberedFamily
}

/// Information shown before a chord is saved.
public enum ShortcutNote: Equatable, Sendable {
    /// Chrome defines the chord; `cmuxWins` says whether cmux's action now
    /// takes it from a focused page (else the page keeps it, because the
    /// action runs only in another context).
    case chromeChord(cmuxWins: Bool)
    /// The user's Ghostty config binds the chord; cmux's registry runs
    /// first, so in a terminal cmux's action wins.
    case ghosttyKeybind(String)
}

/// The recorder's verdict for one chord.
public enum ShortcutAssessment: Equatable, Sendable {
    case refused(ShortcutRefusal)
    /// Free. With notes, the recorder asks before saving.
    case available(notes: [ShortcutNote])
    /// Other actions use it. `canKeepBoth` when every owner runs in a
    /// different context, so the registry picks by context (Cmd-[ is Back
    /// in a page and Focus Back in a terminal). `canReplace` is false when
    /// an owner is a numbered family (replacing it would unbind all nine).
    case conflict(owners: [ActionID], canKeepBoth: Bool, canReplace: Bool, notes: [ShortcutNote])
}

extension ActionRegistry {
    /// Whether `shortcut` can become `id`'s shortcut, and what it collides
    /// with. Pure over the registry's current shortcuts, tiers and contexts.
    public func assessShortcut(_ shortcut: Shortcut, for id: ActionID, environment: ShortcutEditEnvironment) -> ShortcutAssessment {
        let id = canonicalID(for: id)
        if descriptor(for: id)?.shortcutFamily != nil { return .refused(.editsNumberedFamily) }
        guard !shortcut.modifiers.isDisjoint(with: [.command, .control]) else { return .refused(.needsModifier) }
        if let name = SystemReservedShortcuts.table[shortcut] { return .refused(.reservedByMacOS(name: name)) }
        let index = currentShortcutIndex()
        let scope = descriptor(for: id)?.requires ?? []
        let sameScope = { (owner: ActionID) in (self.descriptor(for: owner)?.requires ?? []) == scope }
        var families: [ActionID] = []
        if shortcut.key.count == 1, let digit = shortcut.key.first, ("1"..."9").contains(digit) {
            families = (index.digitFamilies[Shortcut("1", modifiers: shortcut.modifiers)] ?? []).filter { $0 != id }
            if let family = families.first(where: sameScope) { return .refused(.numberedFamily(family)) }
        }
        let owners = (index.byShortcut[shortcut] ?? []).filter { $0 != id } + families
        if let system = owners.first(where: { keyTier(for: $0) == .system }) { return .refused(.systemAction(system)) }
        let notes = shortcutNotes(shortcut, for: id, environment: environment)
        guard !owners.isEmpty else { return .available(notes: notes) }
        return .conflict(owners: owners, canKeepBoth: !owners.contains(where: sameScope), canReplace: families.isEmpty, notes: notes)
    }

    /// Where the key router puts `id`'s chord relative to a page and a
    /// terminal (focus.md section 5): tiers 0 and 1 run app-wide before
    /// either; tier 2 runs before the focused view, but only in its context.
    private func shortcutNotes(_ shortcut: Shortcut, for id: ActionID, environment: ShortcutEditEnvironment) -> [ShortcutNote] {
        var notes: [ShortcutNote] = []
        let requires = descriptor(for: id)?.requires ?? []
        if environment.chromeChords.contains(shortcut) {
            let wins = keyTier(for: id) != .content || requires.contains(.browserFocused)
            notes.append(.chromeChord(cmuxWins: wins))
        }
        if let ghostty = environment.ghosttyBinding(shortcut) {
            notes.append(.ghosttyKeybind(ghostty))
        }
        return notes
    }
}
