/// Which New Tab page template shows (cx-yabk, plans/cmux-next/new-tab-templates.md). The page's
/// dots switch it in place; Terminal skips the page, so New Tab opens a terminal.
public nonisolated enum NewTabTemplate: String, Sendable, Hashable, CaseIterable {
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

/// `tabs.newTabTemplate` in cmux.json. Unset is nil (the page then follows the Debug Settings
/// design tunable); a bad value is nil plus a diagnostic.
nonisolated extension NewTabTemplate {
    public static let configPath = ["tabs", "newTabTemplate"]
    public static let fallback: NewTabTemplate = .default

    static func parse(_ root: JSONValue) -> (NewTabTemplate?, SettingsDiagnostic?) {
        return (nil, nil) // red: not read yet
        guard let value = root.value(at: configPath) else { return (nil, nil) }
        guard let text = value.stringValue, let template = NewTabTemplate(rawValue: text) else {
            let choices = NewTabTemplate.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (nil, SettingsDiagnostic(kind: .invalidValue, path: "tabs.newTabTemplate", message: "expected one of \(choices)"))
        }
        return (template, nil)
    }
}
