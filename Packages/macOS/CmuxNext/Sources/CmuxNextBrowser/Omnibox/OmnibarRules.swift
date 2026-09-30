public import Foundation

/// Text rules the omnibar state machine uses (Chromium's autocomplete rules,
/// reduced to what cmux needs). Pure functions, no state.
public nonisolated enum OmnibarRules {
    /// Text a row puts in the field when it is selected with the arrow keys.
    public static func fillText(for row: BrowserSuggestion) -> String {
        row.kind == .search ? row.title : BrowserURLDisplay.editingText(for: row.url)
    }

    /// The suffix that completes `typed` to `row`'s URL, or nil. Only
    /// navigation and history rows complete, only on a prefix of the URL as
    /// shown (no scheme, no `www.`) or of the full URL, and never for a
    /// trailing space.
    public static func inlineCompletion(for row: BrowserSuggestion, typed: String) -> String? {
        guard row.kind != .search, !typed.isEmpty, typed.last?.isWhitespace == false else { return nil }
        let lowered = typed.lowercased()
        for form in completionForms(of: row.url) where form.lowercased().hasPrefix(lowered) && form.count > typed.count {
            return String(form.dropFirst(typed.count))
        }
        return nil
    }

    /// Pasted text on one line: every line break becomes a space, so UTF-16
    /// offsets (and the caret) stay where they were.
    public static func singleLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return String(text.unicodeScalars.map { CharacterSet.newlines.contains($0) ? " " : Character($0) })
    }

    /// `selection` limited to a text of `length` UTF-16 units. A caret stays
    /// a caret at its own location (`NSIntersectionRange` would turn it into
    /// `{0, 0}`, which once reversed everything typed).
    public static func clamped(_ selection: NSRange, length: Int) -> NSRange {
        guard selection.location != NSNotFound else { return NSRange(location: length, length: 0) }
        let location = min(max(selection.location, 0), length)
        return NSRange(location: location, length: min(max(selection.length, 0), length - location))
    }

    static func length(_ text: String) -> Int { text.utf16.count }

    /// Spellings the user may be typing: the compact display text and the
    /// full URL (for users who type the scheme).
    private static func completionForms(of url: URL) -> [String] {
        var forms = [BrowserURLDisplay.displayText(for: url)]
        let full = url.absoluteString
        forms.append(full.hasSuffix("/") && url.path() == "/" ? String(full.dropLast()) : full)
        return forms.filter { !$0.isEmpty }
    }
}
