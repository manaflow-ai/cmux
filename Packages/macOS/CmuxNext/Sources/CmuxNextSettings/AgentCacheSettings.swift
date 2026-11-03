// The paths, defaults and ranges are generated from schemas/settings/source/agent-cache.json
// (Schema/SettingsSchema+AgentCache.generated.swift); this file only parses.

/// `agents.cacheCompact.*` in cmux.json: whether an idle Claude chat is compacted while its prompt
/// cache is still warm, and above what share of its context. The acpmux daemon reads the same file
/// when it arms the timer and runs it; the app shows and validates the keys.
public nonisolated struct AgentCacheSettings: Sendable, Equatable {
    public var enabled = AgentCacheSettings.cacheCompactEnabledDefault
    public var minContextPercent = AgentCacheSettings.cacheCompactMinContextDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["agents", "cacheCompact"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        if let value = reader.number("minContextPercent", range: cacheCompactMinContextRange) { settings.minContextPercent = value }
        diagnostics += reader.diagnostics
        return settings
    }
}
