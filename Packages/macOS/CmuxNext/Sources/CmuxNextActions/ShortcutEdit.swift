public import AppKit

/// What else a chord may mean where an action's shortcut runs, supplied by
/// the App: the user's Ghostty keybinds and the chords Chrome gives a
/// meaning in a web page (plans/cmux-next/focus.md section 5).
public struct ShortcutEditEnvironment: Sendable {
    /// The cmux action title a Ghostty keybind for this chord maps to, or
    /// the Ghostty action name; nil when Ghostty does not bind it.
    public var ghosttyBinding: @MainActor @Sendable (Shortcut) -> String?
    /// Chrome for Mac's chords (`BrowserChordTable.chromeReserved`).
    public var chromeChords: Set<Shortcut>

    public init(ghosttyBinding: @escaping @MainActor @Sendable (Shortcut) -> String? = { _ in nil }, chromeChords: Set<Shortcut> = []) {
        self.ghosttyBinding = ghosttyBinding
        self.chromeChords = chromeChords
    }
}

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

/// Chords macOS keeps for itself; an app never sees them, or taking them
/// breaks a system feature.
public enum SystemReservedShortcuts {
    public static let table: [Shortcut: String] = [
        Shortcut(" ", modifiers: [.command]): "Spotlight",
        Shortcut(" ", modifiers: [.command, .option]): "Finder search",
        Shortcut(" ", modifiers: [.control]): "Input Sources",
        Shortcut(" ", modifiers: [.control, .command]): "Emoji & Symbols",
        Shortcut("\t", modifiers: [.command]): "App Switcher",
        Shortcut("\t", modifiers: [.command, .shift]): "App Switcher",
        Shortcut("`", modifiers: [.command]): "Cycle Windows",
        Shortcut("`", modifiers: [.command, .shift]): "Cycle Windows",
        Shortcut("3", modifiers: [.command, .shift]): "Screenshot",
        Shortcut("4", modifiers: [.command, .shift]): "Screenshot",
        Shortcut("5", modifiers: [.command, .shift]): "Screenshot",
        Shortcut("6", modifiers: [.command, .shift]): "Screenshot",
        Shortcut("\u{1B}", modifiers: [.command, .option]): "Force Quit",
        Shortcut("q", modifiers: [.control, .command]): "Lock Screen",
        Shortcut("h", modifiers: [.command]): "Hide cmux",
        Shortcut("h", modifiers: [.command, .option]): "Hide Others",
        Shortcut("m", modifiers: [.command]): "Minimize",
        Shortcut("d", modifiers: [.command, .option]): "Dock",
        Shortcut("f", modifiers: [.control, .command]): "Full Screen",
        Shortcut(",", modifiers: [.command]): "Settings",
        Shortcut(Shortcut.upArrowKey, modifiers: [.control]): "Mission Control",
        Shortcut(Shortcut.downArrowKey, modifiers: [.control]): "App Exposé",
        Shortcut(Shortcut.leftArrowKey, modifiers: [.control]): "Move Space",
        Shortcut(Shortcut.rightArrowKey, modifiers: [.control]): "Move Space",
    ]
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
