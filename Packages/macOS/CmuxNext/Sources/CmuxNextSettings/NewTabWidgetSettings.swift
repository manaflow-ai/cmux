// The paths and defaults are generated from schemas/settings/source/new-tab-widgets.json
// (Schema/SettingsSchema+NewTabWidgets.generated.swift); this file only parses.

/// `tabs.newTabWidgets.*` in cmux.json (Leo 2026-10-20: "only do the composer for the default"):
/// the New Tab page is the composer, and each other part of it is a widget the user turns on. The page gets the ones on as ``ids`` (webviews newtab/pageWidgets.ts).
public nonisolated struct NewTabWidgetSettings: Sendable, Equatable {
    /// The headline over the composer that asks "What should we work on in <project>?", the project
    /// an inline picker; off by default (Leo 2026-10-22: "new tab page let's have no greeting text by
    /// default... maybe as toggle but as useful toggle"). The key keeps its old name, so a saved
    /// `true` from the time-of-day greeting turns the headline on.
    public var greeting = NewTabWidgetSettings.greetingDefault
    /// true: cmux.json says `"greeting": false`, not the default. Before the headline was off by
    /// default that turned the greeting off, and the composer sat at the page's top padding; the
    /// page keeps it there for them (no room kept for the headline, newtab/screen.css).
    public var greetingTurnedOff = false
    /// The Default template's card of this Mac and its recent projects.
    public var projects = NewTabWidgetSettings.projectsDefault
    /// The chats that need the user, New Terminal, New Browser Tab and New Chat.
    public var actions = NewTabWidgetSettings.actionsDefault
    /// The recent chats (Minimal shows no Recently Closed list; the palette reopens a closed tab).
    public var chats = NewTabWidgetSettings.chatsDefault
    /// The template dots under the page.
    public var styleDots = NewTabWidgetSettings.styleDotsDefault
    /// The current weather and today's high and low (``NewTabWeather`` in CmuxNextApp).
    public var weather = NewTabWidgetSettings.weatherDefault
    /// The weather's city; empty uses the city of this Mac's time zone.
    public var weatherCity = NewTabWidgetSettings.weatherCityDefault
    /// The machines a chat can start on, each with its color, icon and online state.
    public var machines = NewTabWidgetSettings.machinesDefault
    /// A quiet local clock beside the composer.
    public var clock = NewTabWidgetSettings.clockDefault
    /// A small elapsed-time stopwatch beside the composer.
    public var timer = NewTabWidgetSettings.timerDefault
    /// The original time-of-day greeting wording.
    public var warmGreeting = NewTabWidgetSettings.warmGreetingDefault
    /// A bundled public-domain quote that changes daily.
    public var quote = NewTabWidgetSettings.quoteDefault
    /// The movable widgets in the order the page shows them (`tabs.newTabWidgets.order`,
    /// NewTabWidgetEdits.swift), every one of ``movable`` once.
    public var order = NewTabWidgetSettings.movable

    public init() {}

    /// The widgets on, by the page's names, in the order the page shows them: the headline, the
    /// movable widgets in ``order``, the template dots, then the ambient weather and machines (their
    /// own row under the composer, not moved by the edit mode).
    public var ids: [String] {
        let on = ["greeting": greeting, "projects": projects, "actions": actions, "chats": chats, "styleDots": styleDots,
                  "weather": weather, "machines": machines, "clock": clock, "timer": timer,
                  "warmGreeting": warmGreeting, "quote": quote]
        return (["greeting"] + order + ["styleDots", "weather", "machines", "clock", "timer", "warmGreeting", "quote"]).filter { on[$0] == true }
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["tabs", "newTabWidgets"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("greeting") {
            settings.greeting = value
            settings.greetingTurnedOff = !value
        }
        if let value = reader.bool("projects") { settings.projects = value }
        if let value = reader.bool("actions") { settings.actions = value }
        if let value = reader.bool("chats") { settings.chats = value }
        if let value = reader.bool("styleDots") { settings.styleDots = value }
        if let value = reader.bool("weather") { settings.weather = value }
        if let value = reader.string("weatherCity") {
            settings.weatherCity = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = reader.bool("machines") { settings.machines = value }
        if let value = reader.bool("clock") { settings.clock = value }
        if let value = reader.bool("timer") { settings.timer = value }
        if let value = reader.bool("warmGreeting") { settings.warmGreeting = value }
        if let value = reader.bool("quote") { settings.quote = value }
        diagnostics += reader.diagnostics
        settings.order = parseOrder(root, diagnostics: &diagnostics)
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
