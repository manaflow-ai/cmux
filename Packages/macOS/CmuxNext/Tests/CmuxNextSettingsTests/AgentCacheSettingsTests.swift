import CmuxNextSettings
import Testing

/// `agents.cacheCompact.*` and `agents.coldWake.*`: the app reads the keys the acpmux daemon runs
/// (hub/cache_compact.rs, hub/cold_wake.rs) with the daemon's opt-in defaults and ranges.
struct AgentCacheSettingsTests {
    private func parse(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func defaultsMatchTheDaemon() {
        let cache = parse(.object([:])).agentCache
        #expect(!cache.enabled)
        #expect(cache.minContextTokens == 20_000, "cache_compact.rs DEFAULT_MIN_TOKENS")
        #expect(!cache.coldWakeEnabled)
        #expect(!cache.coldWakeCompact)
        #expect(cache.coldWakeCompactAboveTokens == 100_000, "cold_wake.rs DEFAULT_COMPACT_ABOVE_TOKENS")
        #expect(AgentCacheSettings.cacheCompactMinTokensRange == 10_000...500_000, "cache_compact.rs MIN_TOKENS_RANGE")
        #expect(AgentCacheSettings.coldWakeCompactAboveRange == 10_000...500_000, "cold_wake.rs COMPACT_ABOVE_RANGE")
    }

    @Test(arguments: [false, true]) func cmuxJSONSetsEveryKey(enabled: Bool) {
        let root = JSONValue.object(["agents": .object([
            "cacheCompact": .object(["enabled": .bool(enabled), "minContextPercent": .number(50), "minContextTokens": .number(80_000)]),
            "coldWake": .object(["enabled": .bool(enabled), "compact": .bool(enabled), "compactAboveTokens": .number(150_000)]),
        ])])
        let snapshot = parse(root)
        let cache = snapshot.agentCache
        #expect(cache.enabled == enabled)
        #expect(cache.minContextPercent == 50)
        #expect(cache.minContextTokens == 80_000)
        #expect(cache.coldWakeEnabled == enabled)
        #expect(cache.coldWakeCompact == enabled)
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
        #expect(!snapshot.agentCache.coldWakeCompact, "a value that is not a bool keeps the default")
        let paths = Set(snapshot.diagnostics.map(\.path))
        #expect(paths.isSuperset(of: ["agents.cacheCompact.minContextTokens", "agents.coldWake.compactAboveTokens", "agents.coldWake.compact"]))
    }
}
