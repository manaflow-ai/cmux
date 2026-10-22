// The paths and defaults are generated from schemas/settings/source/new-tab-widgets.json
// (Schema/SettingsSchema+NewTabWidgets.generated.swift); this file only parses.

/// `tabs.newTabWidgets.*` in cmux.json (Leo 2026-10-20: "only do the composer for the default"):
/// the New Tab page is a greeting and the composer, and each other part of it is a widget the user
/// turns on. The page gets the ones on as ``ids`` (webviews newtab/pageWidgets.ts).
public nonisolated struct NewTabWidgetSettings: Sendable, Equatable {
    /// A short greeting by the time of day over the composer.
    public var greeting = NewTabWidgetSettings.greetingDefault
    /// The Default template's card of this Mac and its recent projects.
    public var projects = NewTabWidgetSettings.projectsDefault
    /// The chats that need the user, New Terminal, New Browser Tab and New Chat.
    public var actions = NewTabWidgetSettings.actionsDefault
    /// The template's recent chats and Recently Closed.
    public var chats = NewTabWidgetSettings.chatsDefault
    /// The template dots under the page.
    public var styleDots = NewTabWidgetSettings.styleDotsDefault

    public init() {}

    /// The widgets on, by the page's names, in Settings' order.
    public var ids: [String] {
        [("greeting", greeting), ("projects", projects), ("actions", actions), ("chats", chats),
         ("styleDots", styleDots)].compactMap { $0.1 ? $0.0 : nil }
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["tabs", "newTabWidgets"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("greeting") { settings.greeting = value }
        if let value = reader.bool("projects") { settings.projects = value }
        if let value = reader.bool("actions") { settings.actions = value }
        if let value = reader.bool("chats") { settings.chats = value }
        if let value = reader.bool("styleDots") { settings.styleDots = value }
        diagnostics += reader.diagnostics
        return settings
    }

    /// The diagnostics of bad values, for the snapshot's list.
    static func diagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        var diagnostics: [SettingsDiagnostic] = []
        _ = parse(root, diagnostics: &diagnostics)
        return diagnostics
    }
}

nonisolated extension CmuxConfigSnapshot {
    /// `tabs.newTabWidgets.*`: the New Tab page's widgets (bad values keep their defaults).
    public var newTabWidgets: NewTabWidgetSettings {
        var ignored: [SettingsDiagnostic] = []
        return NewTabWidgetSettings.parse(root, diagnostics: &ignored)
    }
}
