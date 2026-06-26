import CmuxSettings
import Foundation

/// Detects whether a proposed single-stroke command shortcut collides with an
/// existing built-in action binding, a configured cmux action, or another
/// command binding.
///
/// A value type constructed with the current bindings (rather than a free
/// function) so the conflict surface is owned, testable, and not ambient module
/// API. Built-in actions are checked with numbered-digit family semantics so
/// binding `⌃5` is blocked by the `⌃1…9` workspace selector; the proposed
/// command stroke is never itself a numbered family.
@MainActor
struct CommandShortcutConflictChecker {
    /// Built-in action overrides from `shortcuts.bindings`.
    let actionBindings: [String: StoredShortcut]
    /// User-defined cmux config action shortcuts (cmux.json `actions`) as
    /// `(displayLabel, shortcut)` pairs. Dispatched before custom command
    /// shortcuts at runtime, so a command must not be allowed to bind a keystroke
    /// one of these owns. A list, not a map: action titles may collide.
    let configuredActionShortcuts: [(label: String, shortcut: StoredShortcut)]
    /// Other commands' bindings from `shortcuts.commands`.
    let commandShortcuts: [String: StoredShortcut]
    /// Resolves a command id to its display title for the banner.
    let title: (String) -> String

    /// The display label of the first conflicting binding — a built-in action's
    /// display name, a configured action's label, or another command's title —
    /// or `nil` when `stroke` is free. Pass the command id being rebound as
    /// `excludingCommandId` so a command's own existing binding is not treated
    /// as a self-conflict. Comparisons use the first stroke, which also catches a
    /// chord prefix (binding a command to a chord's first stroke would arm the
    /// chord and swallow the key).
    func conflictLabel(stroke: StoredShortcut, excludingCommandId: String?) -> String? {
        for action in ShortcutAction.allCases {
            let effective = actionBindings[action.rawValue] ?? action.defaultShortcut
            guard let effective, !effective.isUnbound else { continue }
            if numberedAwareStrokesConflict(
                stroke.first,
                numbered: false,
                effective.first,
                numbered: action.usesNumberedDigitMatching
            ) {
                return action.displayName
            }
        }
        for entry in configuredActionShortcuts {
            guard !entry.shortcut.isUnbound else { continue }
            if numberedAwareStrokesConflict(stroke.first, numbered: false, entry.shortcut.first, numbered: false) {
                return entry.label
            }
        }
        for (commandId, existing) in commandShortcuts where commandId != excludingCommandId {
            guard !existing.isUnbound else { continue }
            if numberedAwareStrokesConflict(stroke.first, numbered: false, existing.first, numbered: false) {
                return title(commandId)
            }
        }
        return nil
    }
}
