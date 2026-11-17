public import Foundation

/// What the omnibar tells its tab's preloader (`BrowserOmniboxPreloading`),
/// derived from the state after each step: Chrome's omnibox calls
/// `ChromeOmniboxClient::OnTextChanged` while the user edits, with the typed
/// text and the result (the default match first), and
/// `AutocompleteActionPredictor::OnOmniboxOpenedUrl` or `OnRevert` when the
/// edit ends (chrome/browser/ui/omnibox/chrome_omnibox_client.cc). The tab's
/// Chromium decides: confidence >= 0.5 prerenders, >= 0.3 preconnects, search
/// matches never prerender, at most one prerender per tab.
public nonisolated struct OmnibarPreloadRequest: Equatable, Sendable {
    /// What the user typed, without the inline completion.
    public var text: String
    /// The matches on screen, the one Enter loads first.
    public var matches: [OmniboxPreloadMatch]

    /// The request for `state`, or nil when nothing should preload: no edit
    /// in progress, a keyword session, IME composition, rows for older text,
    /// or a default match that loads no web page (Switch to Tab, a
    /// calculator answer, a non-http(s) URL).
    public static func current(_ state: OmnibarState) -> Self? {
        guard state.phase == .editing, state.keyword == nil, !state.isComposing else { return nil }
        let popup = state.popup
        guard !popup.rows.isEmpty, !popup.stale else { return nil }
        let text = state.edit.userText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let current = popup.selected.flatMap { popup.rows.indices.contains($0) ? $0 : nil } ?? 0
        guard let first = match(popup.rows[current], index: current) else { return nil }
        var matches = [first]
        for (index, row) in popup.rows.enumerated() where index != current {
            if let other = match(row, index: index), !matches.contains(other) { matches.append(other) }
        }
        return Self(text: text, matches: matches)
    }

    /// The preload match of a row (Chrome's match type), nil for a row whose
    /// Enter loads no web page.
    static func match(_ row: BrowserSuggestion, index: Int) -> OmniboxPreloadMatch? {
        guard let scheme = row.url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        let kind: OmniboxPreloadMatch.Kind
        switch row.kind {
        case .navigate: kind = .urlWhatYouTyped
        // Row 0 is what was typed; later search rows are the engine's suggestions.
        case .search: kind = index == 0 ? .searchWhatYouTyped : .searchSuggest
        case .history: kind = .historyURL
        case .bookmark: kind = .bookmarkTitle
        case .switchToTab, .answer, .keyword: return nil
        }
        return OmniboxPreloadMatch(url: row.url, kind: kind)
    }

    /// How an edit that ended with `effects` after `input` teaches the
    /// predictor, or nil when it did not end. Chrome learns from an opened
    /// URL only while the popup was open and not from Paste and Go
    /// (`OnOmniboxOpenedUrl`); Escape counts every match as missed
    /// (`OnRevert`); a blur, a keyword session or Switch to Tab forget the
    /// matches unlearned.
    public static func ending(
        _ effects: [OmnibarEffect], input: OmnibarInput, popupWasOpen: Bool
    ) -> (opened: URL?, learn: Bool)? {
        for effect in effects {
            guard case .ended(let reason) = effect else { continue }
            let pasted: Bool = if case .pasteAndGo = input { true } else { false }
            switch reason {
            case .commit(let url), .open(let url, _): return (url, popupWasOpen && !pasted)
            case .cancel: return (nil, true)
            case .blur, .keyword, .switchToTab: return (nil, false)
            }
        }
        return nil
    }
}
