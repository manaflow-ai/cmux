import Foundation

/// How a live Ghostty runtime surface can be reclaimed by hibernation.
enum SurfaceHibernationMechanism: Equatable, Sendable {
    /// The panel runs a restorable coding agent. Hibernation terminates the
    /// scoped agent processes and frees the runtime surface; the agent resumes
    /// with its saved session when the panel is visited again.
    case agentResume
    /// The panel is a plain shell whose recreation has no side effects.
    /// Hibernation captures scrollback, frees the runtime surface (which ends
    /// the shell), and starts a fresh shell in the captured working directory
    /// with the scrollback replayed when the panel is visited again.
    case shellRestart
}

/// One terminal panel as seen by the surface-lifecycle planner.
struct SurfaceHibernationPlannerInput: Sendable {
    let key: AgentHibernationPanelKey
    /// nil when the panel must never be hibernated (deferred startup work,
    /// remote PTY attach, tmux-bound, or queued input that suspension would drop).
    let mechanism: SurfaceHibernationMechanism?
    /// Whether the panel currently owns a live Ghostty runtime surface (or, for
    /// agent panels, a live scoped process). Every live input counts toward the
    /// global cap census even when it is exempt from eviction.
    let isLive: Bool
    /// Visible in the selected workspace's rendered layout.
    let isProtected: Bool
    /// Freeing the PTY could kill live work: the surface is not safely at a
    /// shell prompt (`needsConfirmClose`), the prompt shell has background
    /// child processes, or the terminal owns listening ports.
    let isBusy: Bool
    /// Agent lifecycle reported by hooks; `.unknown` for plain shells.
    let lifecycle: AgentHibernationLifecycleState
    /// Input the user could lose: typed after the last agent lifecycle change
    /// (agent panels) or left pending on the editable command line without a
    /// settling return/interrupt (plain shells).
    let hasUnconfirmedTerminalInput: Bool
    /// Mutable so the controller can fold in tail-fingerprint (output-only)
    /// activity after constructing the input.
    var lastActivityAt: TimeInterval
    /// When the owning workspace last stopped rendering (unmounted), or nil
    /// while it is mounted.
    let workspaceUnmountedAt: TimeInterval?

    init(
        key: AgentHibernationPanelKey,
        mechanism: SurfaceHibernationMechanism?,
        isLive: Bool,
        isProtected: Bool,
        isBusy: Bool = false,
        lifecycle: AgentHibernationLifecycleState = .unknown,
        hasUnconfirmedTerminalInput: Bool = false,
        lastActivityAt: TimeInterval,
        workspaceUnmountedAt: TimeInterval? = nil
    ) {
        self.key = key
        self.mechanism = mechanism
        self.isLive = isLive
        self.isProtected = isProtected
        self.isBusy = isBusy
        self.lifecycle = lifecycle
        self.hasUnconfirmedTerminalInput = hasUnconfirmedTerminalInput
        self.lastActivityAt = lastActivityAt
        self.workspaceUnmountedAt = workspaceUnmountedAt
    }
}

/// Pure selection policy for which live terminal surfaces to hibernate.
///
/// Three rules compose, and the result is their union:
/// - Agent cap: live restorable-agent terminals above
///   `AgentHibernationSettings.maxLiveTerminals`, oldest first.
/// - Global LRU cap: live surfaces of any kind above
///   `SurfaceHibernationSettings.maxLiveSurfaces`, oldest first. The census
///   counts every live surface — including ones materialized by background
///   priming or queued socket input — while only eligible ones are evicted.
/// - Unmounted idle: surfaces whose workspace has been unmounted longer than
///   `SurfaceHibernationSettings.unmountedIdleSeconds`, regardless of cap
///   pressure.
enum SurfaceHibernationPlanner {
    static func selectedPanelKeys(
        inputs: [SurfaceHibernationPlannerInput],
        agentSettings: AgentHibernationSettings.Values,
        surfaceSettings: SurfaceHibernationSettings.Values,
        now: TimeInterval
    ) -> Set<AgentHibernationPanelKey> {
        var selected = agentCapSelection(inputs: inputs, agentSettings: agentSettings, now: now)
        selected.formUnion(
            globalCapSelection(
                inputs: inputs,
                agentSettings: agentSettings,
                surfaceSettings: surfaceSettings,
                now: now
            )
        )
        selected.formUnion(
            unmountedIdleSelection(
                inputs: inputs,
                agentSettings: agentSettings,
                surfaceSettings: surfaceSettings,
                now: now
            )
        )
        return selected
    }

    /// Live restorable-agent terminals above `maxLiveTerminals`, oldest first.
    /// Matches the pre-existing agent hibernation cap exactly.
    private static func agentCapSelection(
        inputs: [SurfaceHibernationPlannerInput],
        agentSettings: AgentHibernationSettings.Values,
        now: TimeInterval
    ) -> Set<AgentHibernationPanelKey> {
        guard agentSettings.enabled else { return [] }
        let liveRestorable = inputs.filter { $0.mechanism == .agentResume && $0.isLive }
        let excess = liveRestorable.count - agentSettings.maxLiveTerminals
        guard excess > 0 else { return [] }

        let eligible = liveRestorable
            .filter { input in
                isEvictable(input, agentSettings: agentSettings) &&
                    now - input.lastActivityAt >= agentSettings.idleSeconds
            }
            .sorted(by: leastRecentlyUsedFirst)

        return Set(eligible.prefix(excess).map(\.key))
    }

    /// Live surfaces of any kind above `maxLiveSurfaces`, oldest first. Every
    /// live surface counts toward the census — including exempt ones — so
    /// surfaces materialized by bypass paths still create eviction pressure.
    private static func globalCapSelection(
        inputs: [SurfaceHibernationPlannerInput],
        agentSettings: AgentHibernationSettings.Values,
        surfaceSettings: SurfaceHibernationSettings.Values,
        now: TimeInterval
    ) -> Set<AgentHibernationPanelKey> {
        guard surfaceSettings.enabled else { return [] }
        let live = inputs.filter(\.isLive)
        let excess = live.count - surfaceSettings.maxLiveSurfaces
        guard excess > 0 else { return [] }

        let eligible = live
            .filter { input in
                guard isEvictable(input, agentSettings: agentSettings) else { return false }
                let idleGate = input.mechanism == .agentResume
                    ? agentSettings.idleSeconds
                    : surfaceSettings.idleSeconds
                return now - input.lastActivityAt >= idleGate
            }
            .sorted(by: leastRecentlyUsedFirst)

        return Set(eligible.prefix(min(excess, maxSelectionsPerEvaluation)).map(\.key))
    }

    /// Hibernating a panel synchronously captures scrollback and frees the
    /// runtime surface on the main actor, so when many hidden terminals become
    /// reclaimable together — cap overflow or a cohort crossing the idle
    /// window — each rule drains a few per evaluation instead of one unbounded
    /// batch. Successive 30s ticks converge on the target.
    static let maxSelectionsPerEvaluation = 4

    /// Surfaces whose workspace has been unmounted — and which have been quiet
    /// — for at least `unmountedIdleSeconds`, regardless of cap pressure.
    /// Oldest first, bounded per evaluation.
    private static func unmountedIdleSelection(
        inputs: [SurfaceHibernationPlannerInput],
        agentSettings: AgentHibernationSettings.Values,
        surfaceSettings: SurfaceHibernationSettings.Values,
        now: TimeInterval
    ) -> Set<AgentHibernationPanelKey> {
        guard surfaceSettings.enabled else { return [] }
        let eligible = inputs
            .filter { input in
                guard input.isLive,
                      isEvictable(input, agentSettings: agentSettings),
                      let workspaceUnmountedAt = input.workspaceUnmountedAt else {
                    return false
                }
                let quietSince = max(input.lastActivityAt, workspaceUnmountedAt)
                return now - quietSince >= surfaceSettings.unmountedIdleSeconds
            }
            .sorted(by: leastRecentlyUsedFirst)
        return Set(eligible.prefix(maxSelectionsPerEvaluation).map(\.key))
    }

    static func isEvictable(
        _ input: SurfaceHibernationPlannerInput,
        agentSettings: AgentHibernationSettings.Values
    ) -> Bool {
        guard !input.isProtected,
              !input.hasUnconfirmedTerminalInput,
              let mechanism = input.mechanism else {
            return false
        }
        switch mechanism {
        case .agentResume:
            // Agent terminals are only reclaimed through their resume path,
            // which the user opts into separately, and only while the agent
            // reports an idle lifecycle.
            return agentSettings.enabled && input.lifecycle.allowsHibernation
        case .shellRestart:
            // Freeing the surface ends the shell, so never reclaim one that is
            // not safely at a prompt.
            return !input.isBusy
        }
    }

    static func leastRecentlyUsedFirst(
        _ lhs: SurfaceHibernationPlannerInput,
        _ rhs: SurfaceHibernationPlannerInput
    ) -> Bool {
        if lhs.lastActivityAt == rhs.lastActivityAt {
            return lhs.key.panelId.uuidString < rhs.key.panelId.uuidString
        }
        return lhs.lastActivityAt < rhs.lastActivityAt
    }
}
