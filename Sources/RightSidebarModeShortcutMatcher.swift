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
    private let bindingsProvider: ((KeyboardShortcutSettings.Action) -> [ConfiguredShortcutBinding])?
    private let availability: Availability
    private let layoutCharacterProvider: LayoutCharacterProvider
    private var entriesByModifierRawValue: [UInt: [RightSidebarModeShortcutEntry]] = [:]

    init(
        shortcutProvider: @escaping ShortcutProvider = KeyboardShortcutSettings.shortcut(for:),
        bindingsProvider: ((KeyboardShortcutSettings.Action) -> [ConfiguredShortcutBinding])? = nil,
        availability: @escaping Availability = { $0.isAvailable() },
        layoutCharacterProvider: @escaping LayoutCharacterProvider = KeyboardLayout.character(forKeyCode:modifierFlags:)
    ) {
        self.shortcutProvider = shortcutProvider
        self.bindingsProvider = bindingsProvider
        self.availability = availability
        self.layoutCharacterProvider = layoutCharacterProvider
        rebuildSnapshot()
    }

    func reload() {
        rebuildSnapshot()
    }

    func modeShortcut(
        for event: NSEvent,
        allowingAction: (KeyboardShortcutSettings.Action) -> Bool
    ) -> RightSidebarMode? {
        modeShortcut(for: event) { entry in
            allowingAction(entry.action)
        }
    }

    func modeShortcut(
        for event: NSEvent,
        allowingBinding: (RightSidebarModeShortcutEntry) -> Bool
    ) -> RightSidebarMode? {
        guard event.type == .keyDown else { return nil }
        let flags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        guard let entries = entriesByModifierRawValue[flags.rawValue] else { return nil }
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
            guard entry.shortcut.matches(
                event: event,
                layoutCharacterProvider: cachedLayoutCharacterProvider
            ), availability(entry.mode), allowingBinding(entry) else { continue }
            return entry.mode
        }
        return nil
    }

    private func rebuildSnapshot() {
        let entries = RightSidebarMode.allCases.flatMap { mode -> [RightSidebarModeShortcutEntry] in
            guard let action = mode.shortcutAction else { return [] }
            let bindings = bindingsProvider?(action)
                ?? [ConfiguredShortcutBinding(
                    shortcut: shortcutProvider(action),
                    whenClause: action.shortcutContext.defaultWhenClause
                )]
            return bindings.compactMap { binding in
                guard !binding.shortcut.isUnbound, !binding.shortcut.hasChord else { return nil }
                return RightSidebarModeShortcutEntry(
                    mode: mode,
                    action: action,
                    shortcut: binding.shortcut,
                    whenClause: binding.whenClause
                )
            }
        }
        entriesByModifierRawValue = Dictionary(grouping: entries) {
            $0.shortcut.modifierFlags.rawValue
        }
    }
}
