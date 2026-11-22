public import Foundation

/// What the field, the suggestion card and the bar show for a state. The
/// effect applier writes it; nothing else writes the field.
public nonisolated struct OmnibarPresentation: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// The compact URL, host at full strength, the rest dimmed.
        case compactURL(URL?)
        /// Plain text at full strength (editing, retained text).
        case plain
    }

    public var text: String
    public var style: Style
    /// The field editor's selection; nil while the field has no focus.
    public var selection: NSRange?
    /// Rows on screen; empty means the card is closed.
    public var rows: [BrowserSuggestion]
    /// The one highlighted row.
    public var highlighted: Int?
    public var hasFocus: Bool
    /// What the leading page-info button shows.
    public var chip: Chip

    /// The leading button: the page's security indicator, or while user
    /// input is in progress an icon for that input (it shows the match type
    /// and opens nothing then).
    public enum Chip: Equatable, Sendable {
        /// User input, or nothing to describe: search, or the highlighted
        /// suggestion's kind.
        case input(symbol: String)
        /// The page's indicator (`PageInfoIndicator`), its text label
        /// included, at rest and while focused: as in Chromium, only user
        /// input replaces it (`LocationIconView::GetShowText`), so focusing
        /// moves nothing (Lawrence 2026-10-30, msg 18159).
        case page
        /// An extension keyword session: the extension's name.
        case keyword(name: String)
        /// A search engine keyword session: "Search YouTube".
        case engineKeyword(label: String)
    }

    public init(_ state: OmnibarState) {
        text = state.fieldText
        switch state.phase {
        case .idle: style = state.retainedText == nil ? .compactURL(state.pageURL) : .plain
        case .committing(let display): style = .compactURL(display)
        case .focused, .editing: style = .plain
        }
        hasFocus = state.hasFocus
        selection = state.hasFocus ? OmnibarRules.clamped(state.edit.selection, length: OmnibarRules.length(text)) : nil
        rows = state.isPopupOpen ? state.popup.rows : []
        highlighted = state.isPopupOpen ? state.popup.highlighted : nil
        chip = Self.chip(for: state)
    }

    private static func chip(for state: OmnibarState) -> Chip {
        let search = PageInfoIndicator.searchSymbol
        if let keyword = state.keyword, state.hasFocus {
            // Chrome's keyword chip for a search engine: "Search YouTube".
            return keyword.searchEngine == nil ? .keyword(name: keyword.name) : .engineKeyword(label: Strings.searchKeyword(engine: keyword.name))
        }
        switch state.phase {
        case .editing:
            if let row = state.popup.highlighted, state.popup.rows.indices.contains(row) {
                return .input(symbol: state.popup.rows[row].kind == .search ? search : "globe")
            }
            return .input(symbol: search)
        case .focused:
            // Chromium `OmniboxView::IsEditingOrEmpty`: an empty box (the New
            // Tab page) shows the search icon, at rest and focused alike.
            return state.permanentText.isEmpty ? .input(symbol: search) : .page
        case .idle, .committing:
            return state.fieldText.isEmpty || state.retainedText != nil ? .input(symbol: search) : .page
        }
    }
}
