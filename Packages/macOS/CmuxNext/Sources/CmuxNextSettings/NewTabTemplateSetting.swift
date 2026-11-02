/// Which New Tab page template shows (cx-yabk, plans/cmux-next/new-tab-templates.md), set in
/// Settings. Terminal draws the default screen: New Tab never opens a terminal by itself.
public nonisolated enum NewTabTemplate: String, Sendable, Hashable, CaseIterable {
    /// The composer; the rest are widgets the user turns on (`tabs.newTabWidgets`, Leo 2026-10-20:
    /// "only do the composer for the default"), with no greeting (Leo 2026-10-22). What an unset key shows.
    case minimal
    /// One rounded field with the Search | Ask switch, the project and agent chips under it, and
    /// three tall chat cards (u2851).
    case cards
    /// The one-field screen with agent rows, chat cards and Tools.
    case `default`
    /// One large prompt field, centered; no cards, no Tools.
    case composer
    /// The field and the recent chats as a list.
    case threads
    /// A monospace field with a `>` glyph and the recent chats as lines.
    case console
    /// The Terminal | Browser | Agent page.
    case classic
    /// No page: New Tab opens a terminal.
    case terminal
}

/// `tabs.newTabTemplate` in cmux.json. Unset is nil (the page then shows ``fallback``, Minimal, unless
/// the Debug Settings design tunable picks Classic); a bad value is nil plus a diagnostic.
nonisolated extension NewTabTemplate {
    public static let configPath = ["tabs", "newTabTemplate"]
    public static let fallback: NewTabTemplate = .minimal

    static func parse(_ root: JSONValue) -> (NewTabTemplate?, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (nil, nil) }
        guard let text = value.stringValue, let template = NewTabTemplate(rawValue: text) else {
            let choices = NewTabTemplate.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (nil, SettingsDiagnostic(kind: .invalidValue, path: "tabs.newTabTemplate", message: "expected one of \(choices)"))
        }
        // Composer was a separate legacy layout. Keep decoding it so existing configs remain
        // readable, but expose the shared Minimal layout as its replacement.
        return (template == .composer ? .minimal : template, nil)
    }
}

extension CmuxConfigSnapshot {
    /// `tabs.newTabTemplate`; nil when unset or invalid (the diagnostic is in `diagnostics`).
    public var newTabTemplate: NewTabTemplate? { NewTabTemplate.parse(root).0 }
}
