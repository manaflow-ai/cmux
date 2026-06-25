import AppKit

/// How many coding agents the user has open, by provider. Drives the Sleepy
/// Mode pets: one cute pet per running agent, to make running lots of agents
/// feel rewarding.
struct SleepyAgentCounts: Equatable, Sendable {
    var claude = 0
    var codex = 0
    var opencode = 0
    var pi = 0
    var other = 0

    var total: Int { claude + codex + opencode + pi + other }
}

/// Samples cmux's live agent registry (the self-reported agent PIDs on every
/// open workspace) at most every couple of seconds. Read from the renderer's
/// Canvas closure, which runs on the main thread.
final class SleepyAgentCensus {
    nonisolated(unsafe) static let shared = SleepyAgentCensus()

    /// DEBUG-only override so automation can summon pets without live agents.
    nonisolated(unsafe) var debugOverride: SleepyAgentCounts?

    private var cached = SleepyAgentCounts()
    private var lastSample: Double = -100
    private let interval: Double = 2

    func sample(at time: Double) -> SleepyAgentCounts {
        if let debugOverride { return debugOverride }
        if time - lastSample >= interval {
            lastSample = time
            cached = MainActor.assumeIsolated { Self.compute() }
        }
        return cached
    }

    @MainActor
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
