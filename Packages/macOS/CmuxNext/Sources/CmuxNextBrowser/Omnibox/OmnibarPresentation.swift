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
    /// input is in progress an icon for that input (Chrome's location icon
    /// shows the match type and opens nothing then).
    public enum Chip: Equatable, Sendable {
        /// User input, or nothing to describe: search, or the highlighted
        /// suggestion's kind.
        case input(symbol: String)
        /// The page's indicator (`PageInfoIndicator`). While focused it keeps
        /// the icon but drops the text label.
        case page(focused: Bool)
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
        let search = PageInfoIndicator.Symbol.search
        switch state.phase {
        case .editing:
            if let row = state.popup.highlighted, state.popup.rows.indices.contains(row) {
                return .input(symbol: state.popup.rows[row].kind == .search ? search : "globe")
            }
            return .input(symbol: search)
        case .focused:
            return state.pageURL == nil ? .input(symbol: search) : .page(focused: true)
        case .idle, .committing:
            return state.fieldText.isEmpty || state.retainedText != nil ? .input(symbol: search) : .page(focused: false)
        }
    }
}
