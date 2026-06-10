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
    /// The surface reports it is not safely at a shell prompt
    /// (`needsConfirmClose`), e.g. a foreground process is running.
    let isBusy: Bool
    /// Agent lifecycle reported by hooks; `.unknown` for plain shells.
    let lifecycle: AgentHibernationLifecycleState
    let hasUnconfirmedTerminalInput: Bool
    let lastActivityAt: TimeInterval
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
        // This mirrors the shipped AgentHibernationPlanner policy: only
        // restorable-agent terminals are counted or evicted, and only under
        // agent-cap pressure. Plain-shell surfaces are invisible to it, the
        // global cap census does not exist, and workspaces unmounted for long
        // periods keep every runtime surface alive
        // (https://github.com/manaflow-ai/cmux/issues/5731).
        guard agentSettings.enabled else { return [] }
        let liveRestorable = inputs.filter { $0.mechanism == .agentResume && $0.isLive }
        let excess = liveRestorable.count - agentSettings.maxLiveTerminals
        guard excess > 0 else { return [] }

        let eligible = liveRestorable
            .filter { input in
                !input.isProtected &&
                    input.lifecycle.allowsHibernation &&
                    !input.hasUnconfirmedTerminalInput &&
                    now - input.lastActivityAt >= agentSettings.idleSeconds
            }
            .sorted(by: Self.leastRecentlyUsedFirst)

        return Set(eligible.prefix(excess).map(\.key))
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
