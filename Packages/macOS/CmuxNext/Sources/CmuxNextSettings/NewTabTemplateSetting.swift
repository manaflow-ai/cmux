/// Which New Tab page template shows (cx-yabk, plans/cmux-next/new-tab-templates.md), set in
/// Settings. Terminal draws the default screen: New Tab never opens a terminal by itself.
public nonisolated enum NewTabTemplate: String, Sendable, Hashable, CaseIterable {
    /// The composer alone (Leo 2026-10-20: "only do the composer for the default"), with no
    /// greeting and no widgets (Lawrence 2026-11-09: "remove widgets completely"). What an unset key shows.
    case minimal
    /// The Terminal | Browser | Agent page.
    case classic
    /// No page: New Tab opens a terminal.
    case terminal

    /// Templates that no longer ship. The legacy Composer, and Cards, Default, Threads and Console,
    /// which moved to looks built on the customization API (Leo 2026-11-18: "The templates should be
    /// like the customixastikms api you can build them i don't think they should ship as is"). A
    /// saved one reads as Minimal with no diagnostic, so an existing cmux.json keeps working.
    static let retired: Set<String> = ["composer", "cards", "default", "threads", "console"]

    /// `text` as a template: a shipped one, Minimal for a retired one, nil for anything else.
    static func reading(_ text: String) -> NewTabTemplate? {
        retired.contains(text) ? .minimal : NewTabTemplate(rawValue: text)
    }
}

/// `tabs.newTabTemplate` in cmux.json. Unset is nil (the page then shows ``fallback``, Minimal, unless
/// the Debug Settings design tunable picks Classic); a bad value is nil plus a diagnostic.
nonisolated extension NewTabTemplate {
    static func parse(_ root: JSONValue) -> (NewTabTemplate?, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (nil, nil) }
        guard let text = value.stringValue, let template = reading(text) else {
            let choices = NewTabTemplate.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (nil, SettingsDiagnostic(kind: .invalidValue, path: "tabs.newTabTemplate", message: "expected one of \(choices)"))
        }
        return (template, nil)
    }
}

extension CmuxConfigSnapshot {
    /// `tabs.newTabTemplate`; nil when unset or invalid (the diagnostic is in `diagnostics`).
    public var newTabTemplate: NewTabTemplate? { NewTabTemplate.parse(root).0 }
}
