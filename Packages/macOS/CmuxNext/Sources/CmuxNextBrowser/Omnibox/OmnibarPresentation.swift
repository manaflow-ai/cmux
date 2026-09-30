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
    }
}
