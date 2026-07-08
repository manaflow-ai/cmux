import AppKit

/// Samples cmux's live agent registry (the self-reported agent PIDs on every
/// open workspace) at most every couple of seconds. `@MainActor`-isolated: it is
/// sampled from the renderer's TimelineView body, the tap gesture, and the debug
/// socket (via `v2MainSync`), all on the main actor, so the cache has enforced
/// isolation rather than relying on `nonisolated(unsafe)` + convention.
@MainActor
final class SleepyAgentCensus: SleepyAgentCensusing {
    enum Bucket: Equatable, Sendable {
        case claude
        case codex
        case opencode
        case pi
        case other
    }

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
                switch bucket(forStatusKey: key) {
                case .claude:
                    counts.claude += 1
                case .codex:
                    counts.codex += 1
                case .opencode:
                    counts.opencode += 1
                case .pi:
                    counts.pi += 1
                case .other:
                    counts.other += 1
                }
            }
        }
        return counts
    }

    nonisolated static func bucket(forStatusKey key: String) -> Bucket {
        let normalized = key.lowercased()
        if normalized.contains("claude") {
            return .claude
        }
        if normalized.contains("codex") {
            return .codex
        }
        if normalized.contains("opencode") || normalized.contains("open-code") {
            return .opencode
        }
        // Live agent-hook PID keys are dotted ("<statusKey>.<sessionId>"),
        // so bucket on the base status key, not the raw dictionary key.
        let baseKey = normalized.split(separator: ".").first.map(String.init) ?? normalized
        if baseKey == "omp" || baseKey == "pi" || baseKey.hasPrefix("pi-") || baseKey.hasPrefix("pi_") || normalized.contains("pi-swarm") || normalized.contains("piswarm") {
            return .pi
        }
        return .other
    }
}
