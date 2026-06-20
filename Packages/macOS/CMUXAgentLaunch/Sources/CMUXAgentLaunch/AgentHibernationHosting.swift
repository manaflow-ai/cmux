public import Foundation

/// The live-workspace operations ``AgentHibernationCoordinator`` reaches back into.
///
/// ``AgentHibernationCoordinator`` owns the agent lifecycle / hibernation /
/// resume-binding *orchestration* bodies the legacy `Workspace` god object kept
/// inline (`setAgentLifecycle`, `clearAgentLifecycle(States)`,
/// `recordAgentLifecycleChange`, `agentHibernationLifecycleState`,
/// `restorableAgentForHibernation`, `enterAgentHibernation`,
/// `resumeAgentHibernation`, `resumeVisibleAgentHibernationPanels`,
/// `restoredAgentResumeStateForAcceptedSnapshot`,
/// `updateRestoredAgentResumeState`, `invalidateRestoredAgentSnapshot`,
/// `clearRestoredAgentSnapshot`, `clearRestoredAgentResumeBinding`,
/// `setSurfaceResumeBinding`, `clearSurfaceResumeBinding`, `surfaceResumeBinding`,
/// `agentHibernationVisiblePanelIdsForCurrentLayout`). The per-panel state those
/// bodies mutate is owned by ``AgentHibernationLifecycleModel`` (injected at
/// init). Everything else the bodies touch is irreducibly app-coupled: the live
/// panel set and focus, the live `TerminalPanel` hibernation entry/resume, the
/// process-id reaping that frees tracked agent ports, the
/// `AgentHibernationController` notifications, the snapshot fingerprint, the
/// rendered-layout visibility, and the DEBUG invalidation log. The bodies call
/// each of those through this seam.
///
/// The app target's `Workspace` conforms and is injected via
/// ``AgentHibernationCoordinator/attach(host:)``. Every method mirrors a call
/// the legacy method bodies made on `self`, so the move is byte-faithful.
///
/// The generic parameters match ``AgentHibernationLifecycleModel``: `Snapshot`
/// is the restorable-agent snapshot, `Binding` the surface resume binding. The
/// seam stays free of the concrete app types so the package graph remains
/// acyclic (the workspace package depends on `CMUXAgentLaunch`, never the
/// reverse).
@MainActor
public protocol AgentHibernationHosting: AnyObject {
    /// The restorable-agent snapshot payload type (app target's
    /// `SessionRestorableAgentSnapshot`).
    associatedtype Snapshot: Sendable
    /// The surface-resume-binding payload type (app target's
    /// `SurfaceResumeBindingSnapshot`).
    associatedtype Binding: Sendable

    // MARK: - Panel existence / focus

    /// Whether a panel with `panelId` currently exists in the workspace
    /// (legacy `panels[panelId] != nil`).
    func agentHibernationPanelExists(_ panelId: UUID) -> Bool

    /// The workspace's currently focused panel id (legacy `focusedPanelId`),
    /// used by `setAgentLifecycle` to default a `nil` target panel.
    func agentHibernationFocusedPanelId() -> UUID?

    /// Focuses the panel (legacy `focusPanel(_:)`), called by
    /// `resumeAgentHibernation` when `focus` is requested.
    func agentHibernationFocusPanel(_ panelId: UUID)

    // MARK: - AgentHibernationController notifications

    /// Notifies the hibernation controller that a panel's agent lifecycle
    /// changed (legacy `AgentHibernationController.shared.recordAgentLifecycleChange(workspaceId:panelId:)`).
    func agentHibernationRecordLifecycleChange(panelId: UUID)

    /// Notifies the hibernation controller that a panel's terminal regained
    /// focus on resume (legacy `AgentHibernationController.shared.recordTerminalFocus(workspaceId:panelId:)`).
    func agentHibernationRecordTerminalFocus(panelId: UUID)

    // MARK: - Snapshot fingerprint

    /// The fingerprint for a restorable-agent snapshot used to detect a snapshot
    /// invalidated for resume (legacy `TabManager.restorableAgentSnapshotFingerprint(_:)`).
    func agentHibernationSnapshotFingerprint(_ snapshot: Snapshot) -> Int

    // MARK: - Live TerminalPanel hibernation

    /// Whether the panel is a live `TerminalPanel` that is not already
    /// hibernated (legacy `panels[panelId] as? TerminalPanel`, `!isAgentHibernated`).
    /// `enterAgentHibernation` early-returns when this is `false`.
    func agentHibernationTerminalPanelCanEnterHibernation(panelId: UUID) -> Bool

    /// Drives `TerminalPanel.enterAgentHibernation(agent:lastActivityAt:)` on
    /// the live panel (legacy `terminalPanel.enterAgentHibernation(...)`).
    func agentHibernationEnterTerminalHibernation(
        panelId: UUID,
        agent: Snapshot,
        lastActivityAt: Date
    )

    /// Whether the panel is a live `TerminalPanel` that is currently hibernated
    /// (legacy `panels[panelId] as? TerminalPanel`, `isAgentHibernated`).
    /// `resumeAgentHibernation` early-returns when this is `false`.
    func agentHibernationTerminalPanelIsHibernated(panelId: UUID) -> Bool

    /// Prepares the live panel's hibernation resume and reports the two flags the
    /// resume body consumes: whether the resume actually proceeded, and whether
    /// startup input was queued (legacy
    /// `terminalPanel.prepareAgentHibernationResume()` returning
    /// `(didResume, queuedStartupInput)`).
    func agentHibernationPrepareTerminalResume(
        panelId: UUID
    ) -> (didResume: Bool, queuedStartupInput: Bool)

    // MARK: - Tracked agent PIDs / ports

    /// The agent-pid status keys owned by the panel (legacy
    /// `agentPIDKeysByPanelId[panelId] ?? []`).
    func agentHibernationAgentPIDKeys(panelId: UUID) -> Set<String>

    /// Clears one tracked agent pid for the panel without refreshing ports or
    /// clearing the status entry (legacy
    /// `clearAgentPID(key:panelId:clearStatus:false, refreshPorts:false)`).
    func agentHibernationClearAgentPID(key: String, panelId: UUID)

    /// Refreshes tracked agent ports after agent pids were cleared
    /// (legacy `refreshTrackedAgentPorts()`).
    func agentHibernationRefreshTrackedAgentPorts()

    // MARK: - Surface resume binding validation

    /// Whether the panel currently maps to a live `TerminalPanel`
    /// (legacy `terminalPanel(for: panelId) != nil`), guarding
    /// `setSurfaceResumeBinding`.
    func agentHibernationTerminalPanelExists(panelId: UUID) -> Bool

    // MARK: - Shell activity (resume-progression input)

    /// Whether the panel's shell is observed running a command (legacy
    /// `panelShellActivityStates[panelId] == .commandRunning`), the input to
    /// `restoredAgentResumeStateForAcceptedSnapshot`.
    func agentHibernationPanelShellIsCommandRunning(panelId: UUID) -> Bool

    // MARK: - Rendered-layout visibility

    /// Whether the auto-resume presentation is currently visible (legacy
    /// `agentHibernationAutoResumePresentationVisible`); `false` short-circuits
    /// `agentHibernationVisiblePanelIdsForCurrentLayout` to the empty set.
    func agentHibernationAutoResumePresentationIsVisible() -> Bool

    /// The panel ids rendered visible by the current layout (legacy
    /// `renderedVisiblePanelIdsForCurrentLayout()`).
    func agentHibernationRenderedVisiblePanelIds() -> Set<UUID>

    // MARK: - DEBUG invalidation log

    /// Logs a restored-agent snapshot invalidation (legacy DEBUG `cmuxDebugLog`
    /// in `invalidateRestoredAgentSnapshot`). The host owns the log sink and the
    /// snapshot's kind/session fields; it is a no-op in release builds.
    func agentHibernationLogInvalidation(panelId: UUID, restoredAgent: Snapshot)

    /// Whether a surface resume binding for `panelId` is the agent-hook binding
    /// whose checkpoint matches `restoredAgent`'s session, and therefore should
    /// be cleared on invalidation (legacy `clearRestoredAgentResumeBinding`
    /// guard: `binding.source == "agent-hook"` and the trimmed `checkpointId` is
    /// `nil` or equal to `restoredAgent.sessionId`). Keeps the binding's `source`
    /// / `checkpointId` and the snapshot's `sessionId` app-side.
    func agentHibernationResumeBindingMatchesAgentHook(
        panelId: UUID,
        restoredAgent: Snapshot
    ) -> Bool

    /// Whether a non-empty startup input is present on the binding (legacy
    /// `setSurfaceResumeBinding` guard: `binding.startupInput` is non-nil and not
    /// blank after trimming). Keeps the binding's `startupInput` app-side.
    func agentHibernationResumeBindingHasStartupInput(_ binding: Binding) -> Bool
}
