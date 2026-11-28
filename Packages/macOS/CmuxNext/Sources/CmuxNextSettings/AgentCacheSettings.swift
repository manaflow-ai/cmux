// The paths, defaults and ranges are generated from schemas/settings/source/agent-cache.json
// (Schema/SettingsSchema+AgentCache.generated.swift); this file only parses.

/// `agents.cacheCompact.*` in cmux.json: whether an idle Claude chat is compacted while its prompt
/// cache is still warm, and above what share of its context or how many tokens, whichever is reached
/// first. `agents.coldWake.*`: whether wakes to a chat whose cache has lapsed are batched into one
/// turn, and whether a Claude chat above `compactAboveTokens` is compacted before the batch goes in
/// (compacting needs batching on). The acpmux daemon reads the same file when it arms the timer and
/// runs it (hub/cache_compact.rs, hub/cold_wake.rs); the app shows and validates the keys.
public nonisolated struct AgentCacheSettings: Sendable, Equatable {
    public var enabled = AgentCacheSettings.cacheCompactEnabledDefault
    public var minContextPercent = AgentCacheSettings.cacheCompactMinContextDefault
    public var minContextTokens = AgentCacheSettings.cacheCompactMinTokensDefault
    public var coldWakeEnabled = AgentCacheSettings.coldWakeEnabledDefault
    public var coldWakeCompact = AgentCacheSettings.coldWakeCompactDefault
    public var coldWakeCompactAboveTokens = AgentCacheSettings.coldWakeCompactAboveDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        if var reader = ConfigFieldReader(root, at: ["agents", "coldWake"], diagnostics: &diagnostics) {
            if let value = reader.bool("enabled") { settings.coldWakeEnabled = value }
            if let value = reader.bool("compact") { settings.coldWakeCompact = value }
            if let value = reader.number("compactAboveTokens", range: coldWakeCompactAboveRange) {
                settings.coldWakeCompactAboveTokens = value
            }
            diagnostics += reader.diagnostics
        }
        guard var reader = ConfigFieldReader(root, at: ["agents", "cacheCompact"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        if let value = reader.number("minContextPercent", range: cacheCompactMinContextRange) { settings.minContextPercent = value }
        if let value = reader.number("minContextTokens", range: cacheCompactMinTokensRange) { settings.minContextTokens = value }
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
