import Foundation

/// Shared validation for runtime plugin bindings.
extension KeyboardShortcutSettings {
    /// Hashes shortcut strokes by their logical key, ignoring recorder-specific key codes.
    private struct PluginShortcutKey: Hashable {
        let firstStroke: ShortcutStroke
        let secondStroke: ShortcutStroke?

        init(_ shortcut: StoredShortcut) {
            firstStroke = Self.normalized(shortcut.firstStroke)
            secondStroke = shortcut.secondStroke.map(Self.normalized)
        }

        private static func normalized(_ stroke: ShortcutStroke) -> ShortcutStroke {
            ShortcutStroke(
                key: stroke.key,
                command: stroke.command,
                shift: stroke.shift,
                option: stroke.option,
                control: stroke.control
            )
        }
    }

    /// Returns a conflicting built-in or active plugin action id, if any.
    /// Plugin actions are global (they have no `shortcuts.when` clause), so a
    /// conservative overlap with any built-in context is rejected.
    static func pluginShortcutConflict(
        _ proposed: StoredShortcut,
        excluding actionID: String,
        activePluginBindings: [String: StoredShortcut],
        configuredCmuxShortcuts: [String: StoredShortcut] = [:]
    ) -> String? {
        var bindings = activePluginBindings
        bindings[actionID] = proposed
        return pluginShortcutConflicts(
            in: bindings,
            configuredCmuxShortcuts: configuredCmuxShortcuts
        )[actionID]
    }

    /// Returns every plugin-to-plugin conflict in one linear projection pass.
    static func pluginShortcutConflicts(
        in bindings: [String: StoredShortcut],
        configuredCmuxShortcuts: [String: StoredShortcut] = [:]
    ) -> [String: String] {
        var singlesByFirstStroke: [ShortcutStroke: [String]] = [:]
        var chordsByFirstStroke: [ShortcutStroke: [String]] = [:]
        var exactChords: [PluginShortcutKey: [String]] = [:]
        for (actionID, shortcut) in bindings where !shortcut.isUnbound {
            let key = PluginShortcutKey(shortcut)
            if shortcut.hasChord {
                chordsByFirstStroke[key.firstStroke, default: []].append(actionID)
                exactChords[key, default: []].append(actionID)
            } else {
                singlesByFirstStroke[key.firstStroke, default: []].append(actionID)
            }
        }
        singlesByFirstStroke.keys.forEach { singlesByFirstStroke[$0]?.sort() }
        chordsByFirstStroke.keys.forEach { chordsByFirstStroke[$0]?.sort() }
        exactChords.keys.forEach { exactChords[$0]?.sort() }

        var conflicts: [String: String] = [:]
        for (actionID, shortcut) in bindings where !shortcut.isUnbound {
            let key = PluginShortcutKey(shortcut)
            if let builtInConflict = Action.allCases.first(where: { action in
                shortcutsConflict(
                    shortcut,
                    proposedUsesNumberedDigitMatching: false,
                    Self.shortcut(for: action),
                    configuredUsesNumberedDigitMatching: action.usesNumberedDigitMatching
                )
            }) {
                conflicts[actionID] = builtInConflict.rawValue
                continue
            }
            if systemWideHotkeyConflicts(
                with: shortcut,
                excluding: .globalSearch
            ) {
                // `.globalSearch` was already checked in Action.allCases above;
                // this reuses the system/hardcoded reservation policy without
                // omitting any effective built-in conflict.
                conflicts[actionID] = "system.reserved"
                continue
            }
            if let configuredConflict = configuredCmuxShortcuts.first(where: { _, configured in
                shortcutsConflict(
                    shortcut,
                    proposedUsesNumberedDigitMatching: false,
                    configured,
                    configuredUsesNumberedDigitMatching: false
                )
            }) {
                conflicts[actionID] = configuredConflict.key
                continue
            }
            if shortcut.hasChord {
                if let single = singlesByFirstStroke[key.firstStroke]?.first {
                    conflicts[actionID] = single
                } else if let duplicate = exactChords[key]?.first(where: {
                    $0 != actionID
                }) {
                    conflicts[actionID] = duplicate
                }
            } else if let duplicate = singlesByFirstStroke[key.firstStroke]?.first(where: {
                $0 != actionID
            }) {
                conflicts[actionID] = duplicate
            } else if let chord = chordsByFirstStroke[key.firstStroke]?.first {
                conflicts[actionID] = chord
            }
        }
        return conflicts
    }
}
