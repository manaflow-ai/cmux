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
    /// `sidebar.hoverCards.groups.*`: the summary cards of workspace groups and tab groups.
    public var groupsWorkspaceGroups = HoverCardSettings.groupsWorkspaceGroupsDefault
    public var groupsTabGroups = HoverCardSettings.groupsTabGroupsDefault
    /// Milliseconds the pointer rests on a group before its card opens.
    public var groupsDelayMilliseconds = HoverCardSettings.groupsDelayDefault
    public var groupsOrder = HoverCardSettings.groupsOrderDefault
    public var groupsMaxMembers = HoverCardSettings.groupsMaxMembersDefault
    public var groupsShowsStatus = HoverCardSettings.groupsSectionStatusDefault
    public var groupsShowsMembers = HoverCardSettings.groupsSectionMembersDefault
    public var groupsShowsActivity = HoverCardSettings.groupsSectionActivityDefault
    public var groupsShowsGit = HoverCardSettings.groupsSectionGitDefault
    public var groupsShowsPorts = HoverCardSettings.groupsSectionPortsDefault

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
        if var groups = ConfigFieldReader(root, at: ["sidebar", "hoverCards", "groups"], diagnostics: &diagnostics) {
            if let value = groups.bool("workspaceGroups") { settings.groupsWorkspaceGroups = value }
            if let value = groups.bool("tabGroups") { settings.groupsTabGroups = value }
            if let value = groups.number("delay", range: groupsDelayRange) { settings.groupsDelayMilliseconds = value }
            if let value = groups.choice("order", GroupHoverCardOrderSetting.self) { settings.groupsOrder = value }
            if let value = groups.number("maxMembers", range: groupsMaxMembersRange) { settings.groupsMaxMembers = value.rounded() }
            diagnostics += groups.diagnostics
        }
        if var sections = ConfigFieldReader(root, at: ["sidebar", "hoverCards", "groups", "sections"], diagnostics: &diagnostics) {
            if let value = sections.bool("status") { settings.groupsShowsStatus = value }
            if let value = sections.bool("members") { settings.groupsShowsMembers = value }
            if let value = sections.bool("activity") { settings.groupsShowsActivity = value }
            if let value = sections.bool("git") { settings.groupsShowsGit = value }
            if let value = sections.bool("ports") { settings.groupsShowsPorts = value }
            diagnostics += sections.diagnostics
        }
        return settings
    }
}
