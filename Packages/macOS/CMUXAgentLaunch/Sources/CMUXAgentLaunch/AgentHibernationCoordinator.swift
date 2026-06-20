public import Foundation

/// Orchestrates the agent lifecycle / hibernation / resume-binding flows for one
/// workspace window.
///
/// This `@MainActor` coordinator is the lifted home of the orchestration bodies
/// the app-target `Workspace` god object kept inline next to its per-panel agent
/// state. The state itself lives in ``AgentHibernationLifecycleModel`` (injected
/// at init and shared with the workspace, which still forwards its former stored
/// properties to that model's dictionaries). This coordinator holds that model
/// plus the live-workspace seam ``AgentHibernationHosting`` and sequences:
/// per-status lifecycle set/clear with the controller notification, aggregate
/// lifecycle resolution, restorable-agent eligibility, hibernation entry and
/// resume on the live `TerminalPanel`, resume-progression advancement and
/// snapshot invalidation, surface resume binding set/clear/read, and the
/// rendered-layout auto-resume visibility query.
///
/// `Workspace` owns one instance and forwards each former method through a
/// one-line forward, so every external call site stays byte-identical. The live
/// work the bodies need (panel existence/focus, the live `TerminalPanel`,
/// tracked-agent-pid reaping, the `AgentHibernationController`, the snapshot
/// fingerprint, rendered visibility, the DEBUG log) is reached through
/// ``AgentHibernationHosting``, conformed by `Workspace` and injected via
/// ``attach(host:)``.
///
/// `@MainActor` because every mutator and reader of this surface originates on
/// the main actor (the workspace model, its UI, and `AgentHibernationController`,
/// which is main-actor), so co-locating the orchestration with its callers keeps
/// the forwards plain calls with no bridging.
///
/// The generic parameters mirror ``AgentHibernationLifecycleModel``: `Host`
/// carries the `Snapshot`/`Binding` payload types, and `Lifecycle` is the
/// per-status agent lifecycle enum. The coordinator never imports the concrete
/// app types, so the package graph stays acyclic.
@MainActor
public final class AgentHibernationCoordinator<Host: AgentHibernationHosting, Lifecycle>
where Lifecycle: Sendable & Equatable {
    /// The restorable-agent snapshot payload type, taken from the host.
    public typealias Snapshot = Host.Snapshot
    /// The surface-resume-binding payload type, taken from the host.
    public typealias Binding = Host.Binding
    /// Resume-progression state, surfaced from the owned lifecycle model so the
    /// app target's `RestoredAgentResumeState` typealias keeps resolving.
    public typealias RestoredAgentResumeState =
        AgentHibernationLifecycleModel<Snapshot, Binding, Lifecycle>.RestoredAgentResumeState

    /// The per-panel agent state this coordinator orchestrates. Shared with the
    /// owning workspace (which forwards its former stored properties to it).
    public let model: AgentHibernationLifecycleModel<Snapshot, Binding, Lifecycle>

    private weak var host: Host?

    /// Creates a coordinator over an existing lifecycle model. Call
    /// ``attach(host:)`` at the composition point before any flow runs.
    public init(model: AgentHibernationLifecycleModel<Snapshot, Binding, Lifecycle>) {
        self.model = model
    }

    /// Injects the live-workspace seam. Set before any orchestration runs so the
    /// controller notifications, panel reads, and side effects reach the workspace.
    public func attach(host: Host) {
        self.host = host
    }

    // MARK: - Per-status lifecycle

    /// Records a per-status lifecycle state for a panel, defaulting a `nil`
    /// target to the focused panel and confirming the panel still exists.
    /// Faithful lift of `Workspace.setAgentLifecycle(key:panelId:lifecycle:)`.
    public func setAgentLifecycle(key: String, panelId: UUID?, lifecycle: Lifecycle) {
        guard let host else { return }
        let targetPanelId = panelId ?? host.agentHibernationFocusedPanelId()
        guard let targetPanelId, host.agentHibernationPanelExists(targetPanelId) else { return }
        model.setLifecycle(
            key: key,
            panelId: targetPanelId,
            lifecycle: lifecycle,
            recordChange: { [weak host] in host?.agentHibernationRecordLifecycleChange(panelId: $0) }
        )
    }

    /// Clears the lifecycle state for a status key on one panel (or every panel
    /// carrying it). Faithful lift of `Workspace.clearAgentLifecycle(key:panelId:)`.
    @discardableResult
    public func clearAgentLifecycle(key: String, panelId: UUID? = nil) -> Bool {
        model.clearLifecycle(
            key: key,
            panelId: panelId,
            recordChange: { [weak host] in host?.agentHibernationRecordLifecycleChange(panelId: $0) }
        )
    }

    /// Clears every lifecycle state for one panel. Faithful lift of
    /// `Workspace.clearAgentLifecycleStates(panelId:)`.
    public func clearAgentLifecycleStates(panelId: UUID) {
        model.clearLifecycleStates(
            panelId: panelId,
            recordChange: { [weak host] in host?.agentHibernationRecordLifecycleChange(panelId: $0) }
        )
    }

    /// Clears every lifecycle state for every panel. Faithful lift of
    /// `Workspace.clearAllAgentLifecycleStates()`.
    public func clearAllAgentLifecycleStates() {
        model.clearAllLifecycleStates(
            recordChange: { [weak host] in host?.agentHibernationRecordLifecycleChange(panelId: $0) }
        )
    }

    /// Resolves the aggregate lifecycle state for a panel against the app's
    /// precedence order. Faithful lift of
    /// `Workspace.agentHibernationLifecycleState(panelId:fallback:)`.
    public func agentHibernationLifecycleState(
        panelId: UUID,
        fallback: Lifecycle?,
        priority: [Lifecycle],
        unknown: Lifecycle
    ) -> Lifecycle {
        model.resolvedLifecycleState(
            panelId: panelId,
            fallback: fallback ?? unknown,
            priority: priority
        ) ?? unknown
    }

    // MARK: - Restorable-agent eligibility

    /// Returns the restorable-agent snapshot eligible for hibernation for a
    /// panel, given the snapshot the caller resolved from the session index, or
    /// `nil` when none is eligible (no resume command, or invalidated for resume).
    /// Faithful lift of `Workspace.restorableAgentForHibernation(panelId:index:)`;
    /// the caller (the `Workspace` forwarder) resolves the index snapshot so the
    /// app-target `RestorableAgentSessionIndex` stays app-side.
    ///
    /// `snapshotHasResumeCommand` mirrors the legacy `snapshot.resumeCommand != nil`
    /// guard, keeping the snapshot's `resumeCommand` field app-side.
    public func restorableAgentForHibernation(
        panelId: UUID,
        indexSnapshot: Snapshot?,
        snapshotHasResumeCommand: (Snapshot) -> Bool
    ) -> Snapshot? {
        guard let snapshot = model.restoredAgentSnapshotsByPanelId[panelId] ?? indexSnapshot,
              snapshotHasResumeCommand(snapshot) else {
            return nil
        }
        let fingerprint = host?.agentHibernationSnapshotFingerprint(snapshot)
        guard model.invalidatedRestoredAgentFingerprintsByPanelId[panelId] != fingerprint else {
            return nil
        }
        return snapshot
    }

    // MARK: - Hibernation entry / resume

    /// Enters hibernation for a panel's live `TerminalPanel` with the given
    /// agent snapshot. Faithful lift of
    /// `Workspace.enterAgentHibernation(panelId:agent:lastActivityAt:)`.
    ///
    /// `agentHasResumeCommand` mirrors the legacy `agent.resumeCommand != nil`
    /// guard, keeping the snapshot's `resumeCommand` field app-side.
    public func enterAgentHibernation(
        panelId: UUID,
        agent: Snapshot,
        lastActivityAt: Date,
        agentHasResumeCommand: (Snapshot) -> Bool
    ) {
        guard let host, host.agentHibernationTerminalPanelCanEnterHibernation(panelId: panelId) else {
            return
        }
        guard agentHasResumeCommand(agent) else { return }
        model.restoredAgentSnapshotsByPanelId[panelId] = agent
        model.restoredAgentResumeStatesByPanelId[panelId] = .manualResumeAvailable
        model.invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        let keys = host.agentHibernationAgentPIDKeys(panelId: panelId)
        for key in keys {
            host.agentHibernationClearAgentPID(key: key, panelId: panelId)
        }
        if !keys.isEmpty {
            host.agentHibernationRefreshTrackedAgentPorts()
        }
        host.agentHibernationEnterTerminalHibernation(
            panelId: panelId,
            agent: agent,
            lastActivityAt: lastActivityAt
        )
    }

    /// Resumes a hibernated panel and optionally focuses it. Faithful lift of
    /// `Workspace.resumeAgentHibernation(panelId:focus:)`.
    @discardableResult
    public func resumeAgentHibernation(panelId: UUID, focus: Bool) -> Bool {
        guard let host, host.agentHibernationTerminalPanelIsHibernated(panelId: panelId) else {
            return false
        }
        let preparation = host.agentHibernationPrepareTerminalResume(panelId: panelId)
        guard preparation.didResume else {
            return false
        }
        if model.restoredAgentSnapshotsByPanelId[panelId] != nil {
            model.restoredAgentResumeStatesByPanelId[panelId] = preparation.queuedStartupInput
                ? .awaitingAutoResumeCommand
                : .manualResumeAvailable
            model.invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: panelId)
        }
        clearAgentLifecycleStates(panelId: panelId)
        host.agentHibernationRecordTerminalFocus(panelId: panelId)
        if focus {
            host.agentHibernationFocusPanel(panelId)
        }
        return true
    }

    /// Resumes every hibernated panel in `panelIds` without focusing. Faithful
    /// lift of `Workspace.resumeVisibleAgentHibernationPanels(panelIds:)`.
    @discardableResult
    public func resumeVisibleAgentHibernationPanels(panelIds: Set<UUID>) -> Bool {
        guard let host else { return false }
        var didResume = false
        for panelId in panelIds {
            guard host.agentHibernationTerminalPanelIsHibernated(panelId: panelId) else {
                continue
            }
            didResume = resumeAgentHibernation(panelId: panelId, focus: false) || didResume
        }
        return didResume
    }

    // MARK: - Resume-progression

    /// The resume-progression state assigned when a restored snapshot is first
    /// accepted for a panel. Faithful lift of
    /// `Workspace.restoredAgentResumeStateForAcceptedSnapshot(panelId:)`.
    public func restoredAgentResumeStateForAcceptedSnapshot(
        panelId: UUID
    ) -> RestoredAgentResumeState {
        model.resumeStateForAcceptedSnapshot(
            isCommandRunning: host?.agentHibernationPanelShellIsCommandRunning(panelId: panelId) ?? false
        )
    }

    /// Advances a panel's resume-progression state for an observed shell
    /// transition and invalidates the snapshot when the progression demands it.
    /// Faithful lift of
    /// `Workspace.updateRestoredAgentResumeState(panelId:restoredAgent:shellState:)`;
    /// the caller (the `Workspace` forwarder) maps its `PanelShellActivityState`
    /// to the two observed-transition flags so that enum stays app-side.
    public func updateRestoredAgentResumeState(
        panelId: UUID,
        restoredAgent: Snapshot,
        isCommandRunning: Bool,
        isPromptIdle: Bool
    ) {
        let shouldInvalidate = model.advanceResumeState(
            panelId: panelId,
            isCommandRunning: isCommandRunning,
            isPromptIdle: isPromptIdle
        )
        if shouldInvalidate {
            invalidateRestoredAgentSnapshot(panelId: panelId, restoredAgent: restoredAgent)
        }
    }

    /// Invalidates a panel's restored-agent snapshot for resume: records its
    /// fingerprint, clears the matching agent-hook resume binding, drops the
    /// snapshot, and logs (DEBUG). Faithful lift of
    /// `Workspace.invalidateRestoredAgentSnapshot(panelId:restoredAgent:)`.
    public func invalidateRestoredAgentSnapshot(
        panelId: UUID,
        restoredAgent: Snapshot
    ) {
        let fingerprint = host?.agentHibernationSnapshotFingerprint(restoredAgent) ?? 0
        model.invalidatedRestoredAgentFingerprintsByPanelId[panelId] = fingerprint
        clearRestoredAgentResumeBinding(panelId: panelId, restoredAgent: restoredAgent)
        clearRestoredAgentSnapshot(panelId: panelId)
        host?.agentHibernationLogInvalidation(panelId: panelId, restoredAgent: restoredAgent)
    }

    /// Drops a panel's restored-agent snapshot and resume-progression state.
    /// Faithful lift of `Workspace.clearRestoredAgentSnapshot(panelId:)`.
    public func clearRestoredAgentSnapshot(panelId: UUID) {
        model.clearRestoredAgentSnapshot(panelId: panelId)
    }

    /// Clears a panel's surface resume binding when it is the agent-hook binding
    /// whose checkpoint matches `restoredAgent`'s session. Faithful lift of
    /// `Workspace.clearRestoredAgentResumeBinding(panelId:restoredAgent:)`; the
    /// guard (binding `source`/`checkpointId` vs snapshot `sessionId`) lives in
    /// the host so those fields stay app-side.
    public func clearRestoredAgentResumeBinding(
        panelId: UUID,
        restoredAgent: Snapshot
    ) {
        guard let host,
              host.agentHibernationResumeBindingMatchesAgentHook(
                panelId: panelId,
                restoredAgent: restoredAgent
              ) else {
            return
        }
        model.surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
    }

    // MARK: - Surface resume binding

    /// Stores a surface resume binding for a panel after validating that the
    /// panel has a live `TerminalPanel` and the binding carries non-empty startup
    /// input. Faithful lift of `Workspace.setSurfaceResumeBinding(_:panelId:)`.
    @discardableResult
    public func setSurfaceResumeBinding(_ binding: Binding, panelId: UUID) -> Bool {
        guard let host,
              host.agentHibernationTerminalPanelExists(panelId: panelId),
              host.agentHibernationResumeBindingHasStartupInput(binding) else {
            return false
        }
        model.setSurfaceResumeBinding(binding, panelId: panelId)
        return true
    }

    /// Removes a panel's surface resume binding, reporting whether one was
    /// present. Faithful lift of `Workspace.clearSurfaceResumeBinding(panelId:)`.
    @discardableResult
    public func clearSurfaceResumeBinding(panelId: UUID) -> Bool {
        model.clearSurfaceResumeBinding(panelId: panelId)
    }

    /// Returns a panel's surface resume binding, if any. Faithful lift of
    /// `Workspace.surfaceResumeBinding(panelId:)`.
    public func surfaceResumeBinding(panelId: UUID) -> Binding? {
        model.surfaceResumeBinding(panelId: panelId)
    }

    // MARK: - Rendered-layout visibility

    /// The panel ids whose hibernation auto-resume presentation is visible in the
    /// current rendered layout, or the empty set when auto-resume presentation is
    /// hidden. Faithful lift of
    /// `Workspace.agentHibernationVisiblePanelIdsForCurrentLayout()`.
    public func agentHibernationVisiblePanelIdsForCurrentLayout() -> Set<UUID> {
        guard let host, host.agentHibernationAutoResumePresentationIsVisible() else { return [] }
        return host.agentHibernationRenderedVisiblePanelIds()
    }
}
