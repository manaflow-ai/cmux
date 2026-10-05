import CmuxSettings
import Foundation

/// What the Keyboard Shortcuts list is filtered by: typed text, keys pressed
/// into the shortcut detector, or both.
struct ShortcutListSearchQuery: Equatable {
    /// Free text ranked against each row's name, then its scope caption and shortcut.
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
    /// Ranks `text` against a row's title and its secondary fields (scope
    /// caption, shortcut glyphs) with the Settings sidebar's fuzzy matcher.
    /// Lower is better; `nil` means no match. Empty text matches everything.
    static func textScore(_ text: String, title: String, details: [String]) -> Int? {
        SettingsSearchMatcher().matchScore(
            query: text,
            title: title,
            secondaryText: details.joined(separator: " ")
        )
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
}

extension ShortcutListModel {
    /// The settings-visible actions that match `query`: best text match first,
    /// display order among equal scores and for a keys-only query.
    func actions(matching query: ShortcutListSearchQuery) -> [ShortcutAction] {
        let actions = ShortcutAction.settingsVisibleActions
        guard !query.isEmpty else { return actions }
        let scored: [(action: ShortcutAction, score: Int)] = actions.compactMap { action in
            let effective = effective(for: action)
            if let keys = query.keys,
               !ShortcutListSearch.keys(keys, match: effective, numbered: action.usesNumberedDigitMatching) {
                return nil
            }
            let shortcutText = effective.flatMap { binding in
                binding.isUnbound ? nil : shortcutDisplayString(binding, numbered: action.usesNumberedDigitMatching)
            } ?? ""
            guard let score = ShortcutListSearch.textScore(
                query.text,
                title: action.displayName,
                details: [scopeCaption(for: action) ?? "", shortcutText]
            ) else {
                return nil
            }
            return (action, score)
        }
        // `sorted` is not stable, so break ties on display position explicitly.
        let position = Dictionary(uniqueKeysWithValues: actions.enumerated().map { ($1, $0) })
        return scored
            .sorted { lhs, rhs in
                lhs.score != rhs.score
                    ? lhs.score < rhs.score
                    : position[lhs.action, default: 0] < position[rhs.action, default: 0]
            }
            .map(\.action)
    }

    /// Refreshes shown matches after a binding change: keeps every row in
    /// `shown` (so an edited row stays put) and appends actions that now match
    /// `query`, in ranked order.
    func actions(matching query: ShortcutListSearchQuery, keeping shown: [ShortcutAction]) -> [ShortcutAction] {
        let shownSet = Set(shown)
        return shown + actions(matching: query).filter { !shownSet.contains($0) }
    }

    /// Whether some settings-visible binding is a chord that starts with `stroke`.
    func hasChord(startingWith stroke: ShortcutStroke) -> Bool {
        ShortcutListSearch.chordStarts(
            with: stroke,
            in: ShortcutAction.settingsVisibleActions.map { effective(for: $0) }
        )
    }
}
