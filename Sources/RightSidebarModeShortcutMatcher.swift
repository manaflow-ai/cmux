import AppKit
import Foundation

/// Settings-invalidated snapshot for the five right-sidebar mode shortcuts.
/// Normal typing misses the modifier bucket without reading settings or the
/// current keyboard layout.
@MainActor
final class RightSidebarModeShortcutMatcher {
    typealias ShortcutProvider = (KeyboardShortcutSettings.Action) -> StoredShortcut
    typealias Availability = (RightSidebarMode) -> Bool
    typealias LayoutCharacterProvider = (UInt16, NSEvent.ModifierFlags) -> String?

    private let shortcutProvider: ShortcutProvider
    private let availability: Availability
    private let layoutCharacterProvider: LayoutCharacterProvider
    /// Stable snapshot used by the AppDelegate matching seam.  That seam also
    /// resolves the active prefix marker, so a chord's suffix modifiers do not
    /// have to match the first stroke's modifier bucket.
    private var allEntries: [RightSidebarModeShortcutEntry] = []
    private var entriesByModifierRawValue: [UInt: [RightSidebarModeShortcutEntry]] = [:]

    init(
        shortcutProvider: @escaping ShortcutProvider = KeyboardShortcutSettings.shortcut(for:),
        availability: @escaping Availability = { $0.isAvailable() },
        layoutCharacterProvider: @escaping LayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) {
        self.shortcutProvider = shortcutProvider
        self.availability = availability
        self.layoutCharacterProvider = layoutCharacterProvider
        rebuildSnapshot()
    }

    func reload() {
        rebuildSnapshot()
    }

    func modeShortcut(
        for event: NSEvent,
        allowingAction: (KeyboardShortcutSettings.Action) -> Bool,
        matching: ((KeyboardShortcutSettings.Action, StoredShortcut, NSEvent) -> Bool)? = nil
    ) -> RightSidebarMode? {
        guard event.type == .keyDown else { return nil }
        let entries: [RightSidebarModeShortcutEntry]
        if matching != nil {
            // The injected matcher is the authoritative path for live cmux
            // routing. It knows whether this event is a chord suffix and must
            // therefore see every snapshot entry, including chords whose
            // second stroke uses different modifiers from the prefix.
            entries = allEntries
        } else {
            let flags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
            // Keep ordinary (single-stroke) typing on the cached modifier
            // bucket. Chords are intentionally absent here: without the live
            // matcher there is no active prefix context to resolve them.
            guard let bucket = entriesByModifierRawValue[flags.rawValue] else { return nil }
            entries = bucket
        }
        var didResolveLayoutCharacter = false
        var layoutCharacter: String?
        let cachedLayoutCharacterProvider: LayoutCharacterProvider = { [layoutCharacterProvider] keyCode, modifiers in
            if !didResolveLayoutCharacter {
                layoutCharacter = layoutCharacterProvider(keyCode, modifiers)
                didResolveLayoutCharacter = true
            }
            return layoutCharacter
        }
        for entry in entries {
            let matches = matching?(entry.action, entry.shortcut, event)
                ?? entry.shortcut.matches(
                    event: event,
                    layoutCharacterProvider: cachedLayoutCharacterProvider
                )
            guard matches, availability(entry.mode), allowingAction(entry.action) else { continue }
            return entry.mode
        }
        return nil
    }

    private func rebuildSnapshot() {
        let entries = RightSidebarMode.allCases.compactMap { mode -> RightSidebarModeShortcutEntry? in
            guard let action = mode.shortcutAction else { return nil }
            let shortcut = shortcutProvider(action)
            guard !shortcut.isUnbound else { return nil }
            return RightSidebarModeShortcutEntry(mode: mode, action: action, shortcut: shortcut)
        }
        allEntries = entries
        entriesByModifierRawValue = Dictionary(grouping: entries.filter { !$0.shortcut.hasChord }) {
            $0.shortcut.modifierFlags.rawValue
        }
    }
}
