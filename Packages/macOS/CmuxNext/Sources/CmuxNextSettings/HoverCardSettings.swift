// The paths, defaults and range are generated from schemas/settings/source/hover-cards.json
// (Schema/SettingsSchema+HoverCards.generated.swift); this file only parses.

/// `sidebar.hoverCards.*` in cmux.json (cx-23e1f): the hover cards of sidebar
/// workspace rows and tabs are on, and wait `HoverCardTiming.showDelay`, unless the user
/// turns them off or sets another delay.
public nonisolated struct HoverCardSettings: Sendable, Equatable {
    public var enabled = HoverCardSettings.enabledDefault
    /// Milliseconds the pointer rests before a card opens.
    public var delayMilliseconds = HoverCardSettings.delayDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["sidebar", "hoverCards"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        if let value = reader.number("delay", range: delayRange) { settings.delayMilliseconds = value }
        diagnostics += reader.diagnostics
        return settings
    }
}
