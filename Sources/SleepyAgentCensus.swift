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
        case ollama
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
        let workspaces = app.openWorkspacesForPetCensus()
        for workspace in workspaces {
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
                case .ollama:
                    counts.ollama += 1
                case .other:
                    counts.other += 1
                }
            }
        }
        addProcessScanOnlyAgents(to: &counts, workspaces: workspaces)
        return counts
    }

    /// Hookless agents (ollama) never self-report a PID, so they are invisible
    /// to the hook census above. Count them from the cached live-agent index
    /// the vault process scanner maintains, gated on the agent process still
    /// being alive so a persisted-for-restore snapshot cannot summon a pet
    /// after its agent exits.
    private static func addProcessScanOnlyAgents(
        to counts: inout SleepyAgentCounts,
        workspaces: [Workspace]
    ) {
        guard let index = SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh() else { return }
        let workspacesByID = Dictionary(
            workspaces.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (panelKey, entry) in index.forkValidationEntries() {
            guard entry.snapshot.kind == .ollama,
                  let workspace = workspacesByID[panelKey.workspaceId],
                  let panel = workspace.terminalPanel(for: panelKey.panelId),
                  workspace.agentPIDKeysByPanelId[panel.id]?.isEmpty ?? true,
                  entry.agentProcessIDs.contains(where: isProcessAlive) else {
                continue
            }
            counts.ollama += 1
        }
    }

    private static func isProcessAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
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
        if normalized.contains("ollama") {
            return .ollama
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
