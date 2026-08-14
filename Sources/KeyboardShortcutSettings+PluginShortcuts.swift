import Foundation

/// Shared validation for runtime plugin bindings.
extension KeyboardShortcutSettings {
    /// Returns a conflicting built-in or active plugin action id, if any.
    /// Plugin actions are global (they have no `shortcuts.when` clause), so a
    /// conservative overlap with any built-in context is rejected.
    static func pluginShortcutConflict(
        _ proposed: StoredShortcut,
        excluding actionID: String
    ) -> String? {
        for action in Action.allCases {
            let configured = shortcut(for: action)
            guard pluginShortcutsConflict(
                proposed,
                proposedUsesNumberedDigits: false,
                configured,
                configuredUsesNumberedDigits: action.usesNumberedDigitMatching
            ) else { continue }
            return action.rawValue
        }

        for (configuredID, configured) in CmuxPluginRuntime.shared.activePluginShortcutBindings()
        where configuredID != actionID {
            guard pluginShortcutsConflict(
                proposed,
                proposedUsesNumberedDigits: false,
                configured,
                configuredUsesNumberedDigits: false
            ) else { continue }
            return configuredID
        }
        return nil
    }

    private static func pluginShortcutsConflict(
        _ lhs: StoredShortcut,
        proposedUsesNumberedDigits: Bool,
        _ rhs: StoredShortcut,
        configuredUsesNumberedDigits: Bool
    ) -> Bool {
        guard !lhs.isUnbound, !rhs.isUnbound else { return false }
        switch (lhs.hasChord, rhs.hasChord) {
        case (false, false):
            return pluginStrokesConflict(
                lhs.firstStroke,
                numberedDigits: proposedUsesNumberedDigits,
                rhs.firstStroke,
                numberedDigits: configuredUsesNumberedDigits
            )
        case (true, true):
            guard pluginStrokesConflict(lhs.firstStroke, numberedDigits: false, rhs.firstStroke, numberedDigits: false),
                  let lhsSecond = lhs.secondStroke,
                  let rhsSecond = rhs.secondStroke else { return false }
            return pluginStrokesConflict(
                lhsSecond,
                numberedDigits: proposedUsesNumberedDigits,
                rhsSecond,
                numberedDigits: configuredUsesNumberedDigits
            )
        case (true, false):
            return pluginStrokesConflict(lhs.firstStroke, numberedDigits: false, rhs.firstStroke, numberedDigits: configuredUsesNumberedDigits)
        case (false, true):
            return pluginStrokesConflict(lhs.firstStroke, numberedDigits: proposedUsesNumberedDigits, rhs.firstStroke, numberedDigits: false)
        }
    }

    private static func pluginStrokesConflict(
        _ lhs: ShortcutStroke,
        numberedDigits lhsNumberedDigits: Bool,
        _ rhs: ShortcutStroke,
        numberedDigits rhsNumberedDigits: Bool
    ) -> Bool {
        guard lhs.command == rhs.command,
              lhs.shift == rhs.shift,
              lhs.option == rhs.option,
              lhs.control == rhs.control else { return false }
        if lhsNumberedDigits || rhsNumberedDigits {
            let lhsIsDigit = isShortcutDigit(lhs.key)
            let rhsIsDigit = isShortcutDigit(rhs.key)
            if lhsIsDigit && rhsIsDigit { return true }
        }
        return lhs.key == rhs.key
    }

    private static func isShortcutDigit(_ key: String) -> Bool {
        guard let value = Int(key) else { return false }
        return (1...9).contains(value)
    }
}
