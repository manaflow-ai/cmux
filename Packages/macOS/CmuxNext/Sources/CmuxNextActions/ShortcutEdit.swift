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
    /// A web page gives the chord a meaning; `cmuxWins` says whether cmux's action now
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
    /// with. Owners come from the binding table the key router resolves
    /// through (``RegistryKeyBindings/table``): catalog keys, cmux.json and
    /// keybindings.json entries, minus negatives; no Ghostty keybinds (noted).
    public func assessShortcut(_ shortcut: Shortcut, for id: ActionID, environment: ShortcutEditEnvironment) -> ShortcutAssessment {
        let id = canonicalID(for: id)
        if descriptor(for: id)?.shortcutFamily != nil { return .refused(.editsNumberedFamily) }
        return assessKey(shortcut, for: id, environment: environment)
    }

    /// The numbered family `id` (`⌘1…9`) on `modifiers`: each of its nine
    /// keys assessed as ``assessKey(_:for:environment:)`` does; the first
    /// that is not available decides, else the notes of all nine.
    public func assessFamilyModifiers(_ modifiers: KeyModifiers, for id: ActionID,
                                      environment: ShortcutEditEnvironment) -> ShortcutAssessment {
        var notes: [ShortcutNote] = []
        for digit in 1...9 {
            switch assessKey(Shortcut(String(digit), modifiers: modifiers), for: id, environment: environment) {
            case .available(let more): notes += more.filter { !notes.contains($0) }
            case let other: return other
            }
        }
        return .available(notes: notes)
    }

    /// ``assessShortcut(_:for:environment:)`` without refusing a numbered
    /// family: `shortcut` as one key of `id`, for an edit of one digit or of
    /// the family's modifiers. `id`'s own entries are not owners: a caller
    /// editing one digit checks the family's other digits itself.
    public func assessKey(_ shortcut: Shortcut, for id: ActionID, environment: ShortcutEditEnvironment) -> ShortcutAssessment {
        let id = canonicalID(for: id)
        guard !shortcut.modifiers.isDisjoint(with: [.command, .control]) else { return .refused(.needsModifier) }
        if let name = SystemReservedShortcuts.shared.table[shortcut] { return .refused(.reservedByMacOS(name: name)) }
        let scope = WhenClause.requiring(descriptor(for: id)?.requires ?? [])
        // The palette resolves only its own entries while it has the keyboard, and the
        // app never sees them (PaletteKeyMap): the two key spaces cannot collide.
        let inPalette = descriptor(for: id)?.requires.contains(.paletteOpen) == true
        let entries = RegistryKeyBindings(self).table.entries.filter {
            $0.keys == [shortcut] && $0.command != id && !$0.source.isGhostty && Self.isPaletteKeySpace($0.when) == inPalette
        }
        let sameScope = { (entry: KeyBinding) in entry.when == scope }
        let familyEntries = entries.filter { $0.argument != nil }
        if let family = familyEntries.first(where: sameScope) { return .refused(.numberedFamily(family.command)) }
        var owners: [ActionID] = []
        for entry in entries.filter({ $0.argument == nil }) + familyEntries where !owners.contains(entry.command) {
            owners.append(entry.command)
        }
        if let system = owners.first(where: { keyTier(for: $0) == .system }) { return .refused(.systemAction(system)) }
        let notes = shortcutNotes(shortcut, for: id, environment: environment)
        guard !owners.isEmpty else { return .available(notes: notes) }
        // Replacing unbinds the owners' cmux.json keys; it cannot remove an
        // app entry or a keybindings.json line, nor one key of a family.
        let layered = keyBindingLayers.app + keyBindingLayers.user
        let canReplace = familyEntries.isEmpty && !entries.contains { layered.contains($0) }
        return .conflict(owners: owners, canKeepBoth: !entries.contains(where: sameScope), canReplace: canReplace, notes: notes)
    }

    /// An entry only the open palette resolves: its `when` requires `paletteOpen`.
    nonisolated static func isPaletteKeySpace(_ when: WhenClause?) -> Bool {
        switch when {
        case .has("paletteOpen")?: true
        case .and(let clauses)?: clauses.contains { isPaletteKeySpace($0) }
        default: false
        }
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
