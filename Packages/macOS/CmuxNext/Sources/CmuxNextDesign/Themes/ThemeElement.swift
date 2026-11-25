import Foundation

/// A chrome element ``ThemeElementAudit`` checks in every theme, as the All Themes playground names it.
public enum ThemeElement: String, CaseIterable, Sendable {
    /// Sidebar row and tab title.
    case title
    /// Sidebar row detail, inactive tab title.
    case detail
    /// Hint and placeholder.
    case hint
    /// Sidebar status dot: unread.
    case dotUnread
    /// Sidebar status dot: needs attention.
    case dotAttention
    /// Sidebar status dot: error.
    case dotError
    /// Unread dot and tab badge.
    case unreadBadge
    /// Spinner.
    case spinner
    /// Status text: attention.
    case statusAttention
    /// Status text: error.
    case statusError
    /// Status text: success.
    case statusSuccess
    /// Lit toolbar glyph.
    case litGlyph
    /// Popover and palette text.
    case popoverText
    /// Popover and palette detail.
    case popoverDetail
    /// Palette and menu highlighted row.
    case highlightedRow
    /// Accent button label.
    case accentLabel
    /// Update button label.
    case updateLabel

    /// The element's name in the playground.
    public var title: String {
        switch self {
        case .title: String(localized: "theme.audit.element.title", defaultValue: "Sidebar row and tab title", bundle: .localizedModule)
        case .detail: String(localized: "theme.audit.element.detail", defaultValue: "Sidebar row detail, inactive tab title", bundle: .localizedModule)
        case .hint: String(localized: "theme.audit.element.hint", defaultValue: "Hint and placeholder", bundle: .localizedModule)
        case .dotUnread: String(localized: "theme.audit.element.dotUnread", defaultValue: "Sidebar status dot: unread", bundle: .localizedModule)
        case .dotAttention: String(localized: "theme.audit.element.dotAttention", defaultValue: "Sidebar status dot: needs attention", bundle: .localizedModule)
        case .dotError: String(localized: "theme.audit.element.dotError", defaultValue: "Sidebar status dot: error", bundle: .localizedModule)
        case .unreadBadge: String(localized: "theme.audit.element.unreadBadge", defaultValue: "Unread dot and tab badge", bundle: .localizedModule)
        case .spinner: String(localized: "theme.audit.element.spinner", defaultValue: "Spinner", bundle: .localizedModule)
        case .statusAttention: String(localized: "theme.audit.element.statusAttention", defaultValue: "Status text: attention", bundle: .localizedModule)
        case .statusError: String(localized: "theme.audit.element.statusError", defaultValue: "Status text: error", bundle: .localizedModule)
        case .statusSuccess: String(localized: "theme.audit.element.statusSuccess", defaultValue: "Status text: success", bundle: .localizedModule)
        case .litGlyph: String(localized: "theme.audit.element.litGlyph", defaultValue: "Lit toolbar glyph", bundle: .localizedModule)
        case .popoverText: String(localized: "theme.audit.element.popoverText", defaultValue: "Popover and palette text", bundle: .localizedModule)
        case .popoverDetail: String(localized: "theme.audit.element.popoverDetail", defaultValue: "Popover and palette detail", bundle: .localizedModule)
        case .highlightedRow: String(localized: "theme.audit.element.highlightedRow", defaultValue: "Palette and menu highlighted row", bundle: .localizedModule)
        case .accentLabel: String(localized: "theme.audit.element.accentLabel", defaultValue: "Accent button label", bundle: .localizedModule)
        case .updateLabel: String(localized: "theme.audit.element.updateLabel", defaultValue: "Update button label", bundle: .localizedModule)
        }
    }
}
