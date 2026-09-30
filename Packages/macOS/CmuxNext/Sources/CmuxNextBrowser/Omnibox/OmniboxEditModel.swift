public import Foundation

/// The omnibar's editing rules, as a pure value so every behavior is unit
/// tested (Chromium's `OmniboxEditModel`, reduced to what cmux needs):
///
/// - Focus shows the full URL, all selected.
/// - Typing asks for suggestions; the first row is the default match, and a
///   history row whose URL extends what was typed is completed inline (the
///   completion is selected, so typing on replaces it). Deleting never
///   completes, so Backspace removes the completion instead of re-adding it.
/// - Up and Down move through rows and show the row's text; returning to the
///   first row restores what was typed.
/// - Escape reverts to the page URL (all selected); a second Escape, with
///   nothing left to revert, cancels editing.
/// - Enter commits the selected row, else what was typed.
public nonisolated struct OmniboxEditModel: Equatable, Sendable {
    /// What the field shows and which part of it is selected.
    public struct Presentation: Equatable, Sendable {
        public var text: String
        /// UTF-16 range, as `NSTextView` expects.
        public var selection: NSRange
    }

    /// What Escape did.
    public enum EscapeResult: Equatable, Sendable {
        /// The text went back to the page URL; editing continues.
        case reverted
        /// Nothing to revert: end editing and return focus to the page.
        case cancel
    }

    public private(set) var isEditing = false
    /// The page URL, as the field shows it while editing.
    public private(set) var permanentText = ""
    /// Exactly what the user typed (no inline completion).
    public private(set) var userText = ""
    /// The selected suffix appended to `userText`, if any.
    public private(set) var inlineCompletion = ""
    public private(set) var suggestions: [BrowserSuggestion] = []
    /// Selected row, nil when no popup rows are shown.
    public private(set) var selectedIndex: Int?
    /// True once the user changed the text in this editing session.
    public private(set) var userHasEdited = false
    private var lastEditWasDeletion = false

    public init() {}

    public var isPopupOpen: Bool { !suggestions.isEmpty }

    /// The field's text and selection for the current state.
    public var presentation: Presentation {
        if !userHasEdited {
            return Presentation(text: permanentText, selection: NSRange(location: 0, length: permanentText.utf16.count))
        }
        if let selectedIndex, selectedIndex > 0, suggestions.indices.contains(selectedIndex) {
            let text = Self.fillText(for: suggestions[selectedIndex])
            let end = text.utf16.count
            return Presentation(text: text, selection: NSRange(location: end, length: 0))
        }
        let text = userText + inlineCompletion
        return Presentation(
            text: text,
            selection: NSRange(location: userText.utf16.count, length: inlineCompletion.utf16.count)
        )
    }

    // MARK: Transitions

    /// Focus arrived: show the full URL of `url`, all selected.
    public mutating func begin(url: URL?) {
        self = OmniboxEditModel()
        isEditing = true
        permanentText = BrowserURLDisplay.editingText(for: url)
    }

    /// The page URL changed while editing. Untouched text follows it.
    public mutating func pageURLChanged(_ url: URL?) {
        permanentText = BrowserURLDisplay.editingText(for: url)
    }

    /// The user changed the field to `text`. `isDeletion` is true for
    /// Backspace, Delete, and cut, which never complete inline.
    public mutating func userEdited(_ text: String, isDeletion: Bool) {
        isEditing = true
        userHasEdited = true
        userText = text
        inlineCompletion = ""
        lastEditWasDeletion = isDeletion
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            suggestions = []
            selectedIndex = nil
        }
    }

    /// Rows arrived for `text`. Stale results (the user typed on) are dropped.
    /// Returns whether the model changed.
    @discardableResult
    public mutating func received(_ rows: [BrowserSuggestion], for text: String) -> Bool {
        guard isEditing, userHasEdited, text == userText else { return false }
        var rows = rows
        inlineCompletion = ""
        if !lastEditWasDeletion, !rows.isEmpty,
           let index = rows.firstIndex(where: { Self.inlineCompletion(for: $0, typed: text) != nil }),
           let completion = Self.inlineCompletion(for: rows[index], typed: text) {
            // The completed row becomes the default match.
            let row = rows.remove(at: index)
            rows.insert(row, at: 0)
            inlineCompletion = completion
        }
        suggestions = rows
        selectedIndex = rows.isEmpty ? nil : 0
        return true
    }

    /// Up (-1) or Down (+1). Clamps at both ends like Chromium.
    public mutating func move(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let next = min(max((selectedIndex ?? 0) + delta, 0), suggestions.count - 1)
        selectedIndex = next
    }

    /// Selects a row (hover or click) without committing.
    public mutating func select(_ index: Int) {
        guard suggestions.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// Escape: close the popup and revert, or cancel when nothing changed.
    public mutating func escape() -> EscapeResult {
        let changed = userHasEdited || isPopupOpen
        revert()
        return changed ? .reverted : .cancel
    }

    /// Enter: the destination, or nil when the text resolves to nothing.
    public func commitDestination(resolver: OmniboxResolver) -> URL? {
        if !userHasEdited {
            return permanentText.isEmpty ? nil : resolver.destination(for: permanentText)?.url
        }
        if let selectedIndex, suggestions.indices.contains(selectedIndex) {
            return suggestions[selectedIndex].url
        }
        return resolver.destination(for: userText + inlineCompletion)?.url
    }

    /// Editing ended (commit, cancel, or focus left the field).
    public mutating func end() {
        self = OmniboxEditModel()
    }

    private mutating func revert() {
        userText = ""
        inlineCompletion = ""
        userHasEdited = false
        suggestions = []
        selectedIndex = nil
        lastEditWasDeletion = false
    }

    // MARK: Rules

    /// Text a row puts in the field when selected with the arrow keys.
    public static func fillText(for row: BrowserSuggestion) -> String {
        row.kind == .search ? row.title : BrowserURLDisplay.editingText(for: row.url)
    }

    /// The suffix that completes `typed` to `row`'s URL, or nil. Only
    /// navigation and history rows complete, only on a prefix of the URL as
    /// shown (no scheme, no `www.`), and never for a trailing space or a
    /// typed scheme the URL does not share.
    public static func inlineCompletion(for row: BrowserSuggestion, typed: String) -> String? {
        guard row.kind != .search, !typed.isEmpty, typed.last?.isWhitespace == false else { return nil }
        let candidates = completionForms(of: row.url)
        let lowered = typed.lowercased()
        for form in candidates where form.lowercased().hasPrefix(lowered) && form.count > typed.count {
            return String(form.dropFirst(typed.count))
        }
        return nil
    }

    /// Spellings the user may be typing: the compact display text and the
    /// full URL (for users who type the scheme).
    private static func completionForms(of url: URL) -> [String] {
        var forms = [BrowserURLDisplay.displayText(for: url)]
        let full = url.absoluteString
        forms.append(full.hasSuffix("/") && url.path() == "/" ? String(full.dropLast()) : full)
        return forms.filter { !$0.isEmpty }
    }
}
