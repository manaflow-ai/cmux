public import Foundation

/// Text rules the omnibar state machine uses (Chromium's autocomplete rules,
/// reduced to what cmux needs). Pure functions, no state.
public nonisolated enum OmnibarRules {
    /// Text a row puts in the field when it is selected with the arrow keys.
    public static func fillText(for row: BrowserSuggestion) -> String {
        switch row.kind {
        case .search: row.title
        case .keyword, .answer: row.content ?? row.title
        case .navigate, .history, .bookmark, .switchToTab: BrowserURLDisplay.editingText(for: row.url)
        }
    }

    /// The suffix that completes `typed` to `row`'s URL, or nil. Only
    /// navigation, history and bookmark rows the pipeline marked
    /// `inlineCompletable` complete, only on a prefix of the URL as shown (no
    /// scheme, no `www.`) or of the full URL, and never for a trailing space.
    /// Search, remote and Switch to Tab rows never complete.
    public static func inlineCompletion(for row: BrowserSuggestion, typed: String) -> String? {
        guard row.inlineCompletable, row.kind != .search, row.kind != .keyword, row.kind != .switchToTab, row.kind != .answer,
              !typed.isEmpty, typed.last?.isWhitespace == false else { return nil }
        let lowered = typed.lowercased()
        for form in completionForms(of: row.url) where form.lowercased().hasPrefix(lowered) && form.count > typed.count {
            return String(form.dropFirst(typed.count))
        }
        return nil
    }

    /// The Control-Enter URL for `typed`: `www.` and `.com` around a host
    /// that has no dot (`example`, `google/maps`, `www.example`), nil for
    /// anything else (a scheme, a port, spaces, a host with a TLD).
    public static func desiredTLDURL(for typed: String, resolver: BrowserURLResolver) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace), !text.contains(":") else { return nil }
        let hostEnd = text.firstIndex { "/?#".contains($0) } ?? text.endIndex
        var host = String(text[..<hostEnd]).lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty, !host.contains("."), !host.contains("@"),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return resolver.url(for: "www.\(host).com" + text[hostEnd...])
    }

    /// Pasted text on one line: every line break becomes a space, so UTF-16
    /// offsets (and the caret) stay where they were.
    public static func singleLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return String(text.unicodeScalars.map { CharacterSet.newlines.contains($0) ? " " : Character($0) })
    }

    /// Text dropped on the omnibox, as Chromium `OmniboxViewViews::PerformDrop` cleans it: runs of
    /// whitespace become one space, the ends are trimmed, and leading `javascript:` schemes (any
    /// case, with the spaces after them) are stripped (`omnibox::StripJavascriptSchemas`).
    static func droppedText(_ text: String) -> String {
        var cleaned = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let scheme = "javascript:"
        while cleaned.lowercased().hasPrefix(scheme) {
            cleaned = String(cleaned.dropFirst(scheme.count)).trimmingCharacters(in: .whitespaces)
        }
        return cleaned
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

    /// `url` is the https upgrade of scheme-less typed `text`: the text
    /// names no scheme and resolves to this https URL by itself.
    static func isHTTPSUpgrade(of text: String, to url: URL, resolver: BrowserURLResolver) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard url.scheme?.lowercased() == "https", !trimmed.contains("://") else { return false }
        return resolver.url(for: trimmed) == url
    }
}

/// What Copy and Cut put on the pasteboard for the omnibar's selection.
public nonisolated struct OmnibarCopy: Equatable, Sendable {
    public var text: String
    /// Also written as a URL (a hyperlink to the page).
    public var url: URL?
}

nonisolated extension OmnibarReducer {
    /// Copy of the field's selection, adjusted as Chromium does
    /// (`omnibox::AdjustTextForCopy` in components/omnibox/browser/
    /// omnibox_text_util.cc); nil when nothing is selected.
    ///
    /// - A selection that does not start at the beginning is copied as is.
    /// - The whole untouched URL, elided or full, copies the page URL.
    /// - Otherwise text that reads as a URL on the same host as the page (or
    ///   the arrowed row) gets that page's scheme and is copied as a URL.
    public static func copyContent(of state: OmnibarState, resolver: OmniboxResolver) -> OmnibarCopy? {
        guard state.hasFocus else { return nil }
        let text = state.fieldText as NSString
        let selection = OmnibarRules.clamped(state.edit.selection, length: text.length)
        guard selection.length > 0 else { return nil }
        let selected = text.substring(with: selection)
        guard selection.location == 0 else { return OmnibarCopy(text: selected, url: nil) }
        let modified = state.phase != .focused || (selected != state.displayText && selected != state.permanentText)
        if !modified, let page = state.pageURL {
            return OmnibarCopy(text: page.absoluteString, url: page)
        }
        guard case .url(var url)? = resolver.destination(for: selected) else {
            return OmnibarCopy(text: selected, url: nil)
        }
        var current = state.pageURL
        if state.isPopupOpen, let row = state.popup.selected, state.popup.rows.indices.contains(row),
           state.popup.rows[row].kind != .search {
            current = state.popup.rows[row].url
        }
        guard let current, isHTTP(current), isHTTP(url), current.host() == url.host() else {
            return OmnibarCopy(text: selected, url: nil)
        }
        let lowered = selected.lowercased()
        if !lowered.hasPrefix("http://"), !lowered.hasPrefix("https://"),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = current.scheme
            if let rewritten = components.url { url = rewritten }
        }
        return OmnibarCopy(text: url.absoluteString, url: url)
    }

    private static func isHTTP(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
    }
}
