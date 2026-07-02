import AppKit

/// Samples cmux's live agent registry (the self-reported agent PIDs on every
/// open workspace) at most every couple of seconds. `@MainActor`-isolated: it is
/// sampled from the renderer's TimelineView body, the tap gesture, the
/// notifications page header (`NotificationAgentCountsView`), and the debug
/// socket (via `v2MainSync`), all on the main actor, so the cache has enforced
/// isolation rather than relying on `nonisolated(unsafe)` + convention.
@MainActor
final class SleepyAgentCensus: SleepyAgentCensusing {
    /// DEBUG-only override so automation can summon pets without live agents.
    var debugOverride: SleepyAgentCounts?

    private var cached = SleepyAgentCounts()
    private var lastSample: Double = -100
    private let interval: Double = 2

    func sample(at time: Double) -> SleepyAgentCounts {
        if let debugOverride { return debugOverride }
        if time - lastSample >= interval {
            lastSample = time
            cached = Self.compute()
        }
        return cached
    }

    private static func compute() -> SleepyAgentCounts {
        guard let app = AppDelegate.shared else { return SleepyAgentCounts() }
        var counts = SleepyAgentCounts()
        for workspace in app.openWorkspacesForPetCensus() {
            for (key, pid) in workspace.agentPIDs where pid > 0 {
                let normalized = key.lowercased()
                if normalized.contains("claude") {
                    counts.claude += 1
                } else if normalized.contains("codex") {
                    counts.codex += 1
                } else if normalized.contains("opencode") || normalized.contains("open-code") {
                    counts.opencode += 1
                } else if normalized == "pi" || normalized.hasPrefix("pi-") || normalized.hasPrefix("pi_") || normalized.contains("pi-swarm") || normalized.contains("piswarm") {
                    counts.pi += 1
                } else {
                    counts.other += 1
                }
            }
        }
        return counts
    }
}
