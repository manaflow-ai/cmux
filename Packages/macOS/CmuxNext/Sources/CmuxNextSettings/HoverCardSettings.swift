// The paths, defaults and range are generated from schemas/settings/source/hover-cards.json
// (Schema/SettingsSchema+HoverCards.generated.swift); this file only parses.

/// `sidebar.hoverCards.*` in cmux.json (cx-23e1f): the hover cards of sidebar
/// workspace rows and tabs are on, and wait `HoverCardTiming.showDelay`, unless the user
/// turns them off or sets another delay. The workspace card's layout, sections and history
/// length (u3320) too.
public nonisolated struct HoverCardSettings: Sendable, Equatable {
    public var enabled = HoverCardSettings.enabledDefault
    /// Milliseconds the pointer rests before a card opens.
    public var delayMilliseconds = HoverCardSettings.delayDefault
    /// The workspace card's design (`sidebar.hoverCards.layout`).
    public var layout = HoverCardSettings.layoutDefault
    /// `sidebar.hoverCards.sections.*`: which parts the workspace card shows.
    public var showsTimings = HoverCardSettings.timingsDefault
    public var showsPrompts = HoverCardSettings.promptsDefault
    public var showsWaiting = HoverCardSettings.waitingDefault
    public var showsGit = HoverCardSettings.gitDefault
    public var showsPorts = HoverCardSettings.portsDefault
    /// The most history lines the workspace card lists (`sidebar.hoverCards.maxRows`).
    public var maxRows = HoverCardSettings.maxRowsDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["sidebar", "hoverCards"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        if let value = reader.number("delay", range: delayRange) { settings.delayMilliseconds = value }
        if let value = reader.choice("layout", HoverCardLayoutSetting.self) { settings.layout = value }
        if let value = reader.number("maxRows", range: maxRowsRange) { settings.maxRows = value.rounded() }
        diagnostics += reader.diagnostics
        if var sections = ConfigFieldReader(root, at: ["sidebar", "hoverCards", "sections"], diagnostics: &diagnostics) {
            if let value = sections.bool("timings") { settings.showsTimings = value }
            if let value = sections.bool("prompts") { settings.showsPrompts = value }
            if let value = sections.bool("waiting") { settings.showsWaiting = value }
            if let value = sections.bool("git") { settings.showsGit = value }
            if let value = sections.bool("ports") { settings.showsPorts = value }
            diagnostics += sections.diagnostics
        }
        return settings
    }
}
