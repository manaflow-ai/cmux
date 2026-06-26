/// Decides whether two recorded keyboard shortcuts collide, accounting for
/// the numbered-digit-family matching used by the "Select Surface 1…9" and
/// "Select Workspace 1…9" actions.
///
/// This is a stateless value type: every method is a pure function of its
/// shortcut/stroke arguments, except ``conflictingAction(for:excluding:)``,
/// which reads each action's currently configured shortcut through
/// ``KeyboardShortcutSettings/shortcut(for:)`` and consults the action's own
/// ``KeyboardShortcutSettings/Action/conflicts(with:proposedAction:configuredShortcut:)``.
/// Relocated verbatim from the static-method cluster that previously lived on
/// `enum KeyboardShortcutSettings`; behavior is byte-identical.
struct ShortcutConflictResolver {
    /// How a stroke participates in a conflict comparison: an `.exact` keystroke
    /// match, or membership in the numbered-digit `1…9` family.
    private enum MatchMode {
        case exact
        case numberedDigitFamily
    }

    /// Returns the first existing action (other than `currentAction`) whose
    /// configured shortcut conflicts with `proposedShortcut`, or `nil` when the
    /// proposed shortcut is free to assign.
    func conflictingAction(
        for proposedShortcut: StoredShortcut,
        excluding currentAction: KeyboardShortcutSettings.Action
    ) -> KeyboardShortcutSettings.Action? {
        for action in KeyboardShortcutSettings.Action.allCases where action != currentAction {
            let configuredShortcut = KeyboardShortcutSettings.shortcut(for: action)
            if action.conflicts(
                with: proposedShortcut,
                proposedAction: currentAction,
                configuredShortcut: configuredShortcut
            ) {
                return action
            }
        }
        return nil
    }

    /// Whether the proposed and configured shortcuts collide, honoring each
    /// side's numbered-digit-family matching and chord shape.
    func shortcutsConflict(
        _ proposedShortcut: StoredShortcut,
        proposedUsesNumberedDigitMatching: Bool,
        _ configuredShortcut: StoredShortcut,
        configuredUsesNumberedDigitMatching: Bool
    ) -> Bool {
        guard !proposedShortcut.isUnbound, !configuredShortcut.isUnbound else {
            return false
        }

        switch (proposedShortcut.hasChord, configuredShortcut.hasChord) {
        case (false, false):
            return shortcutStrokeMatchersConflict(
                proposedShortcut.firstStroke,
                mode: proposedUsesNumberedDigitMatching ? .numberedDigitFamily : .exact,
                configuredShortcut.firstStroke,
                mode: configuredUsesNumberedDigitMatching ? .numberedDigitFamily : .exact
            )
        case (true, true):
            guard strokesConflict(proposedShortcut.firstStroke, configuredShortcut.firstStroke),
                  let proposedSecond = proposedShortcut.secondStroke,
                  let configuredSecond = configuredShortcut.secondStroke else {
                return false
            }
            return shortcutStrokeMatchersConflict(
                proposedSecond,
                mode: proposedUsesNumberedDigitMatching ? .numberedDigitFamily : .exact,
                configuredSecond,
                mode: configuredUsesNumberedDigitMatching ? .numberedDigitFamily : .exact
            )
        case (true, false):
            return shortcutStrokeMatchersConflict(
                proposedShortcut.firstStroke,
                mode: .exact,
                configuredShortcut.firstStroke,
                mode: configuredUsesNumberedDigitMatching ? .numberedDigitFamily : .exact
            )
        case (false, true):
            return shortcutStrokeMatchersConflict(
                proposedShortcut.firstStroke,
                mode: proposedUsesNumberedDigitMatching ? .numberedDigitFamily : .exact,
                configuredShortcut.firstStroke,
                mode: .exact
            )
        }
    }

    private func shortcutStrokeMatchersConflict(
        _ lhs: ShortcutStroke,
        mode lhsMode: MatchMode,
        _ rhs: ShortcutStroke,
        mode rhsMode: MatchMode
    ) -> Bool {
        switch (lhsMode, rhsMode) {
        case (.exact, .exact):
            return strokesConflict(lhs, rhs)
        case (.numberedDigitFamily, .numberedDigitFamily):
            return numberedDigitStrokeConflict(lhs, rhs)
        case (.numberedDigitFamily, .exact):
            return numberedDigitStrokeConflictsWithExactStroke(lhs, rhs)
        case (.exact, .numberedDigitFamily):
            return numberedDigitStrokeConflictsWithExactStroke(rhs, lhs)
        }
    }

    private func numberedDigitStrokeConflictsWithExactStroke(
        _ numberedStroke: ShortcutStroke,
        _ exactStroke: ShortcutStroke
    ) -> Bool {
        guard isNumberedDigitStroke(numberedStroke), isNumberedDigitStroke(exactStroke) else {
            return false
        }
        return numberedStroke.command == exactStroke.command &&
            numberedStroke.shift == exactStroke.shift &&
            numberedStroke.option == exactStroke.option &&
            numberedStroke.control == exactStroke.control
    }

    private func numberedDigitStrokeConflict(_ lhs: ShortcutStroke, _ rhs: ShortcutStroke) -> Bool {
        guard isNumberedDigitStroke(lhs), isNumberedDigitStroke(rhs) else { return false }
        return lhs.command == rhs.command &&
            lhs.shift == rhs.shift &&
            lhs.option == rhs.option &&
            lhs.control == rhs.control
    }

    private func isNumberedDigitStroke(_ stroke: ShortcutStroke) -> Bool {
        guard let digit = Int(stroke.key) else { return false }
        return (1...9).contains(digit)
    }

    private func strokesConflict(_ lhs: ShortcutStroke, _ rhs: ShortcutStroke) -> Bool {
        lhs.key == rhs.key &&
            lhs.command == rhs.command &&
            lhs.shift == rhs.shift &&
            lhs.option == rhs.option &&
            lhs.control == rhs.control
    }
}
