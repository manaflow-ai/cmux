/// `announcements.*` in cmux.json (R114): the cmux announcement cards above
/// Settings. `enabled` false hides them for good (Settings or the palette's
/// Show Announcements brings them back); `fetch` false means no network for them.
public nonisolated struct AnnouncementsSettings: Sendable, Equatable {
    // Paths and defaults: schemas/settings/source/updates.json (SettingsSchema+Updates.generated.swift).
    public var enabled = AnnouncementsSettings.enabledDefault
    public var fetch = AnnouncementsSettings.fetchDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["announcements"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        if let value = reader.bool("fetch") { settings.fetch = value }
        diagnostics = reader.diagnostics
        return settings
    }
}
