import CmuxSettings
import Foundation

extension ShortcutListModel {
    /// The red validation-banner text for `action`, or `nil` when no rejection is pending.
    func validationMessage(for action: ShortcutAction) -> String? {
        if systemReservedRejections.contains(action.rawValue) {
            return String(
                localized: "shortcut.recorder.error.reservedBySystem",
                defaultValue: "This keystroke is reserved by macOS."
            )
        }
        if numberedDigitRejections.contains(action.rawValue) {
            return String(
                localized: "shortcut.recorder.error.numberedShortcutRequiresDigit",
                defaultValue: "Use a digit from 1 through 9."
            )
        }
        if bareKeyRejections.contains(action.rawValue) {
            return String(
                localized: "shortcut.recorder.error.bareKeyNotAllowed",
                defaultValue: "Shortcuts must include ⌘ ⌥ ⌃ or ⇧"
            )
        }
        if let conflict = conflictRejections[action.rawValue] {
            let conflictEffective = effective(for: conflict)
            let conflictShortcutString = conflictEffective.map {
                shortcutDisplayString($0, numbered: conflict.usesNumberedDigitMatching)
            } ?? ""
            let messageFormat = String(
                localized: "shortcut.recorder.error.conflictsWithAction",
                defaultValue: "This shortcut conflicts with %@ (%@)."
            )
            return String.localizedStringWithFormat(
                messageFormat,
                conflict.displayName,
                conflictShortcutString
            )
        }
        return nil
    }
}
