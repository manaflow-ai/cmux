import CmuxNextSettings
import Testing

/// `agents.cacheCompact.*` and `agents.coldWake.*`: the app reads the keys the acpmux daemon runs
/// (hub/cache_compact.rs, hub/cold_wake.rs) with the daemon's defaults and ranges (Leo, 2026-11-24:
/// "this can be toggled but... this as a default seems decent.").
struct AgentCacheSettingsTests {
    private func parse(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func defaultsMatchTheDaemon() {
        let cache = parse(.object([:])).agentCache
        #expect(cache.enabled)
        #expect(cache.minContextTokens == 60_000, "cache_compact.rs DEFAULT_MIN_TOKENS")
        #expect(cache.coldWakeEnabled)
        #expect(cache.coldWakeCompact)
        #expect(cache.coldWakeCompactAboveTokens == 100_000, "cold_wake.rs DEFAULT_COMPACT_ABOVE_TOKENS")
        #expect(AgentCacheSettings.cacheCompactMinTokensRange == 10_000...500_000, "cache_compact.rs MIN_TOKENS_RANGE")
        #expect(AgentCacheSettings.coldWakeCompactAboveRange == 10_000...500_000, "cold_wake.rs COMPACT_ABOVE_RANGE")
    }

    @Test func cmuxJSONSetsEveryKey() {
        let root = JSONValue.object(["agents": .object([
            "cacheCompact": .object(["enabled": .bool(false), "minContextPercent": .number(50), "minContextTokens": .number(80_000)]),
            "coldWake": .object(["enabled": .bool(false), "compact": .bool(false), "compactAboveTokens": .number(150_000)]),
        ])])
        let snapshot = parse(root)
        let cache = snapshot.agentCache
        #expect(!cache.enabled)
        #expect(cache.minContextPercent == 50)
        #expect(cache.minContextTokens == 80_000)
        #expect(!cache.coldWakeEnabled)
        #expect(!cache.coldWakeCompact)
        #expect(cache.coldWakeCompactAboveTokens == 150_000)
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("agents.") })
    }

    @Test func outOfRangeTokensClampWithADiagnostic() {
        let root = JSONValue.object(["agents": .object([
            "cacheCompact": .object(["minContextTokens": .number(1_000)]),
            "coldWake": .object(["compactAboveTokens": .number(9_000_000), "compact": .string("yes")]),
        ])])
        let snapshot = parse(root)
        #expect(snapshot.agentCache.minContextTokens == 10_000)
        #expect(snapshot.agentCache.coldWakeCompactAboveTokens == 500_000)
        #expect(snapshot.agentCache.coldWakeCompact, "a value that is not a bool keeps the default")
        let paths = Set(snapshot.diagnostics.map(\.path))
        #expect(paths.isSuperset(of: ["agents.cacheCompact.minContextTokens", "agents.coldWake.compactAboveTokens", "agents.coldWake.compact"]))
    }
}
