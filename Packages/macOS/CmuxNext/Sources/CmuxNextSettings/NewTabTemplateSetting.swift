/// Which New Tab page template shows (cx-yabk, plans/cmux-next/new-tab-templates.md), set in
/// Settings. Terminal is no page: a person's New Tab opens a terminal instead (the page, opened another way, draws the default screen).
///
/// cmux ships Minimal and Classic (and Terminal). The Cards, Default, Threads and Console pages no
/// longer ship (Leo 2026-11-18: "The templates should be like the customixastikms api you can build
/// them i don't think they should ship as is"): each is a template a person builds and edits
/// (skills/cmux-customization/templates/newtab-*, a `cmux.newtab/1` page picked with
/// `tabs.newTabApp`). Their ids, and the legacy Composer one, still decode so a saved config stays
/// readable, and load as Minimal (``isRetired``).
public nonisolated enum NewTabTemplate: String, Sendable, Hashable, CaseIterable {
    /// The composer alone (Leo 2026-10-20: "only do the composer for the default"), with no
    /// greeting and no widgets (Lawrence 2026-11-09: "remove widgets completely"). What an unset key shows.
    case minimal
    /// Retired: now the `newtab-cards` template a person builds. Loads as Minimal.
    case cards
    /// Retired: now the `newtab-calm` template a person builds. Loads as Minimal.
    case `default`
    /// Retired: the same one-composer page as Minimal. Loads as Minimal.
    case composer
    /// Retired: now the `newtab-threads` template a person builds. Loads as Minimal.
    case threads
    /// Retired: now the `newtab-console` template a person builds. Loads as Minimal.
    case console
    /// The Terminal | Browser | Agent page.
    case classic
    /// Terminal-first (picked at the first run, cmux#48416): a person's New Tab (Cmd-T) opens a
    /// terminal (cmux-window-rules `tabs::new_tab_kind`), and splits keep the terminal.
    case terminal

    /// A template cmux no longer ships: a saved one loads as Minimal, and no page or Settings write saves it.
    public var isRetired: Bool {
        switch self {
        case .cards, .default, .composer, .threads, .console: true
        case .minimal, .classic, .terminal: false
        }
    }

    /// What this template shows: Minimal for a retired one, else itself.
    public var shipped: NewTabTemplate { isRetired ? .minimal : self }
}

/// `tabs.newTabTemplate` in cmux.json. Unset is nil (the page then shows ``fallback``, Minimal, unless
/// the Debug Settings design tunable picks Classic); a bad value is nil plus a diagnostic.
nonisolated extension NewTabTemplate {
    static func parse(_ root: JSONValue) -> (NewTabTemplate?, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (nil, nil) }
        guard let text = value.stringValue, let template = NewTabTemplate(rawValue: text) else {
            let choices = NewTabTemplate.allCases.filter { !$0.isRetired }.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (nil, SettingsDiagnostic(kind: .invalidValue, path: "tabs.newTabTemplate", message: "expected one of \(choices)"))
        }
        // A retired template stays readable so an existing config keeps working; it shows Minimal.
        return (template.shipped, nil)
    }
}

extension CmuxConfigSnapshot {
    /// `tabs.newTabTemplate`; nil when unset or invalid (the diagnostic is in `diagnostics`).
    public var newTabTemplate: NewTabTemplate? { NewTabTemplate.parse(root).0 }
}
