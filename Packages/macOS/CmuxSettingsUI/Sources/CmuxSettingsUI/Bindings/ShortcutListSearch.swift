import CmuxSettings
import Foundation

/// What the Keyboard Shortcuts list is filtered by: typed text, keys pressed
/// into the shortcut detector, or both.
struct ShortcutListSearchQuery: Equatable {
    /// Free text matched against each row's name, scope caption and shortcut.
    var text = ""
    /// Keys pressed into the detector: one stroke, or both strokes of a chord.
    var keys: StoredShortcut?
    /// Bumped on every detection so pressing the same keys again re-runs the
    /// match after bindings changed.
    var detection = 0

    var isEmpty: Bool {
        keys == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Pure matching rules for ``ShortcutListSearchQuery``.
enum ShortcutListSearch {
    /// Whether every whitespace-separated word of `text` appears in one of
    /// `fields`, ignoring case and diacritics. Empty text matches everything.
    static func text(_ text: String, matches fields: [String]) -> Bool {
        let words = normalized(text).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = normalized(fields.joined(separator: " "))
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Whether pressing `keys` runs `binding`.
    ///
    /// One pressed stroke finds the bindings that fire on it and the chords
    /// that start with it, so the detector can show a chord before its second
    /// stroke. Two pressed strokes find only the chord made of both. Digit
    /// families (``ShortcutAction/usesNumberedDigitMatching``) match any digit
    /// from 1 through 9, as they do at runtime.
    static func keys(_ keys: StoredShortcut, match binding: StoredShortcut?, numbered: Bool) -> Bool {
        guard let binding, !binding.isUnbound, !keys.isUnbound else { return false }
        guard let pressedSecond = keys.second else {
            return numberedAwareStrokesConflict(
                keys.first,
                numbered: false,
                binding.first,
                numbered: numbered && binding.second == nil
            )
        }
        guard let bindingSecond = binding.second else { return false }
        return numberedAwareStrokesConflict(keys.first, numbered: false, binding.first, numbered: false)
            && numberedAwareStrokesConflict(pressedSecond, numbered: false, bindingSecond, numbered: numbered)
    }

    /// Whether some chord in `bindings` starts with `stroke`, meaning the
    /// detector should wait for a second stroke.
    static func chordStarts(with stroke: ShortcutStroke, in bindings: [StoredShortcut?]) -> Bool {
        bindings.contains { binding in
            guard let binding, binding.hasChord else { return false }
            return numberedAwareStrokesConflict(stroke, numbered: false, binding.first, numbered: false)
        }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

extension ShortcutListModel {
    /// The settings-visible actions that match `query`, in display order.
    func actions(matching query: ShortcutListSearchQuery) -> [ShortcutAction] {
        let actions = ShortcutAction.settingsVisibleActions
        guard !query.isEmpty else { return actions }
        return actions.filter { action in
            let effective = effective(for: action)
            if let keys = query.keys,
               !ShortcutListSearch.keys(keys, match: effective, numbered: action.usesNumberedDigitMatching) {
                return false
            }
            let shortcutText = effective.flatMap { binding in
                binding.isUnbound ? nil : shortcutDisplayString(binding, numbered: action.usesNumberedDigitMatching)
            } ?? ""
            return ShortcutListSearch.text(
                query.text,
                matches: [action.displayName, scopeCaption(for: action) ?? "", shortcutText]
            )
        }
    }

    /// Whether some settings-visible binding is a chord that starts with `stroke`.
    func hasChord(startingWith stroke: ShortcutStroke) -> Bool {
        ShortcutListSearch.chordStarts(
            with: stroke,
            in: ShortcutAction.settingsVisibleActions.map { effective(for: $0) }
        )
    }
}
