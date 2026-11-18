// The paths, defaults and ranges are generated from schemas/settings/source/agent-cache.json
// (Schema/SettingsSchema+AgentCache.generated.swift); this file only parses.

/// `agents.cacheCompact.*` in cmux.json: when a Claude chat is compacted around its prompt cache
/// (before it expires, or when you return after it did), and above what size. The acpmux daemon
/// reads the same file when it arms the timer or sends a message; the app shows and validates the keys.
public nonisolated struct AgentCacheSettings: Sendable, Equatable {
    /// `agents.cacheCompact.mode` as written; nil when absent (then `enabled` decides, see `effectiveMode`).
    public var mode: CacheCompactMode?
    /// The legacy switch: with no `mode`, true means `.beforeExpiry`.
    public var enabled = AgentCacheSettings.cacheCompactEnabledDefault
    public var minContextPercent = AgentCacheSettings.cacheCompactMinContextDefault
    public var returnMinTokens = AgentCacheSettings.cacheCompactReturnMinTokensDefault

    public init() {}

    /// The mode acpmux runs: `mode` when set, else `.beforeExpiry` for a legacy `enabled: true`,
    /// else the default (`.off`).
    public var effectiveMode: CacheCompactMode {
        if let mode { return mode }
        return enabled ? .beforeExpiry : AgentCacheSettings.cacheCompactModeDefault
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["agents", "cacheCompact"], diagnostics: &diagnostics) else { return settings }
        settings.mode = reader.choice("mode", CacheCompactMode.self)
        if let value = reader.bool("enabled") { settings.enabled = value }
        if let value = reader.number("minContextPercent", range: cacheCompactMinContextRange) { settings.minContextPercent = value }
        if let value = reader.number("returnMinTokens", range: cacheCompactReturnMinTokensRange) { settings.returnMinTokens = value }
        diagnostics += reader.diagnostics
        return settings
    }

    /// `agents.autoRetry.*` and `agents.cacheCompact.*`, the settings the acpmux daemon runs, read into the
    /// snapshot (here, not in CmuxConfigSnapshot, which is at its god-type cap).
    static func parseDaemonSettings(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
        snapshot.agentRetry = AgentRetrySettings.parse(root, diagnostics: &snapshot.diagnostics)
        snapshot.agentCache = parse(root, diagnostics: &snapshot.diagnostics)
    }
}
