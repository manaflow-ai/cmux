import AppKit

/// Provider bucket for one self-reported agent, shared by the Sleepy Mode pet
/// census and the notifications-header agent popover so both classify keys
/// identically.
enum RunningAgentProvider: Int, CaseIterable, Sendable {
    case claude, codex, opencode, pi, other

    static func classify(key: String) -> RunningAgentProvider {
        let normalized = key.lowercased()
        if normalized.contains("claude") {
            return .claude
        } else if normalized.contains("codex") {
            return .codex
        } else if normalized.contains("opencode") || normalized.contains("open-code") {
            return .opencode
        } else if normalized == "pi" || normalized.hasPrefix("pi-") || normalized.hasPrefix("pi_") || normalized.contains("pi-swarm") || normalized.contains("piswarm") {
            return .pi
        }
        return .other
    }

    /// Provider names are brand names and stay unlocalized; only the
    /// catch-all bucket is translated.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "opencode"
        case .pi: return "pi"
        case .other:
            return String(localized: "notifications.agentCounts.other", defaultValue: "Other")
        }
    }
}

/// One self-reported agent process, for the notifications-header popover.
struct RunningAgentSnapshot: Equatable, Identifiable {
    let provider: RunningAgentProvider
    let key: String
    let workspaceId: UUID
    let workspaceTitle: String
    let pid: pid_t
    /// Kernel-reported process start time; nil when the PID is gone or the
    /// sysctl fails (the row then renders without a duration).
    let startDate: Date?

    var id: String { "\(workspaceId.uuidString)/\(key)" }
}

/// Kernel process start times, cached per PID (a start time never changes for
/// a live PID; a recycled PID gets a fresh lookup only after eviction, which
/// is fine at this feature's 1–2s sampling cadence and small agent counts).
@MainActor
enum ProcessStartTime {
    private static var cache: [pid_t: Date] = [:]

    static func startDate(pid: pid_t) -> Date? {
        if let hit = cache[pid] { return hit }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
            return nil
        }
        let tv = info.kp_proc.p_starttime
        let date = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
        cache[pid] = date
        return date
    }
}

/// Samples cmux's live agent registry (the self-reported agent PIDs on every
/// open workspace) at most every couple of seconds. `@MainActor`-isolated: it is
/// sampled from the renderer's TimelineView body, the tap gesture, the
/// notifications header (`NotificationAgentCountsView`), and the debug
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
                switch RunningAgentProvider.classify(key: key) {
                case .claude: counts.claude += 1
                case .codex: counts.codex += 1
                case .opencode: counts.opencode += 1
                case .pi: counts.pi += 1
                case .other: counts.other += 1
                }
            }
        }
        return counts
    }

    /// Uncached per-agent detail for the notifications-header popover: every
    /// self-reported agent with its provider, host workspace, and process
    /// start time. One pass is O(open tabs) plus one cached sysctl per agent.
    static func liveAgents() -> [RunningAgentSnapshot] {
        guard let app = AppDelegate.shared else { return [] }
        var agents: [RunningAgentSnapshot] = []
        for workspace in app.openWorkspacesForPetCensus() {
            for (key, pid) in workspace.agentPIDs where pid > 0 {
                agents.append(RunningAgentSnapshot(
                    provider: RunningAgentProvider.classify(key: key),
                    key: key,
                    workspaceId: workspace.id,
                    workspaceTitle: workspace.title,
                    pid: pid,
                    startDate: ProcessStartTime.startDate(pid: pid)
                ))
            }
        }
        return agents
    }
}
