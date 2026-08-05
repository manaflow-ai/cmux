import CmuxSettings
import Foundation

extension ShortcutListModel {
    /// Whether the recorder should retain its rejected stroke for `action`.
    func hasPendingRejection(for action: ShortcutAction) -> Bool {
        let actionID = action.rawValue
        return bareKeyRejections.contains(actionID)
            || primaryModifierRejections.contains(actionID)
            || systemReservedRejections.contains(actionID)
            || numberedDigitRejections.contains(actionID)
            || conflictRejections[actionID] != nil
    }

    /// The red validation-banner text for `action`, or `nil` when no rejection is pending.
    func validationMessage(for action: ShortcutAction) -> String? {
        if primaryModifierRejections.contains(action.rawValue) {
            return String(
                localized: "shortcut.recorder.error.systemWideHotkeyRequiresModifier",
                defaultValue: "System-wide hotkeys must include Command, Option, or Control."
            )
        }
        if systemReservedRejections.contains(action.rawValue) {
            return String(
                localized: "shortcut.recorder.error.reservedBySystem",
                defaultValue: "This keystroke is reserved by macOS."
            )
        }
        if numberedDigitRejections.contains(action.rawValue) {
            let range = action.numberedDigitRange ?? 1...9
            let format = String(
                localized: "shortcut.recorder.error.numberedShortcutRequiresDigitRange",
                defaultValue: "Use a digit from %lld through %lld."
            )
            return String.localizedStringWithFormat(
                format,
                Int64(range.lowerBound),
                Int64(range.upperBound)
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
                shortcutDisplayString($0, numberedRange: conflict.numberedDigitRange)
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
