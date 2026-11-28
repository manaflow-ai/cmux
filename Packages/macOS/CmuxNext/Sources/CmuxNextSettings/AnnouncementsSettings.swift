/// `announcements.*` in cmux.json (R114): the cmux announcement cards above
/// Settings. `enabled` false hides them for good (Settings or the palette's
/// Show Announcements brings them back); `fetch` false means no network for them.
public nonisolated struct AnnouncementsSettings: Sendable, Equatable {
    public static let enabledPath = ["announcements", "enabled"]
    public static let fetchPath = ["announcements", "fetch"]
    public var enabled = true
    public var fetch = true

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
