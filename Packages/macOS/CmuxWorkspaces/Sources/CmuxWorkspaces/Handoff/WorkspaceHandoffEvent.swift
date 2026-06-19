public import Foundation

/// A mount/handoff state transition the ``WorkspaceHandoffCoordinator`` made,
/// handed to the window host so it can emit the legacy DEBUG trace line.
///
/// The coordinator carries no logging of its own: the legacy
/// `cmuxDebugLog("ws.mount.reconcile …" / "ws.handoff.…")` lines depended on
/// the per-window `TabManager` DEBUG workspace-switch snapshot (`id`/`dt`) and
/// the `debugShortWorkspaceId`/`debugShortWorkspaceIds`/`debugMsText`
/// formatters, all app-target. Rather than drag that DEBUG tracing
/// infrastructure into the package, the coordinator reports the structured
/// transition (only the workspace ids and reasons it knows) and the host (in
/// `#if DEBUG`) prepends the snapshot `id`/`dt` and formats the byte-identical
/// line. In release builds the host method is a no-op, exactly as the original
/// `#if DEBUG`-guarded `cmuxDebugLog` calls were. This mirrors
/// ``PendingWorkspaceUnfocusEvent``.
public enum WorkspaceHandoffEvent: Sendable {
    /// The mounted set changed during a reconcile (legacy `ws.mount.reconcile`,
    /// emitted only when `mountedWorkspaceIds != previousMountedIds`). Carries
    /// the cycle-hot flag, the effective selected id, and the new/added/removed
    /// id lists in the legacy order.
    case mountReconciled(
        isCycleHot: Bool,
        selectedWorkspaceId: UUID?,
        mountedWorkspaceIds: [UUID],
        addedWorkspaceIds: [UUID],
        removedWorkspaceIds: [UUID]
    )
    /// A workspace handoff began (legacy `ws.handoff.start`). Carries the
    /// outgoing and incoming selected ids.
    case handoffStarted(oldSelectedWorkspaceId: UUID, newSelectedWorkspaceId: UUID)
    /// The incoming workspace was ready for immediate handoff (legacy
    /// `ws.handoff.fastReady`). Carries the newly selected id.
    case handoffFastReady(selectedWorkspaceId: UUID)
    /// A handoff completed (legacy `ws.handoff.complete`). Carries the
    /// completion reason and the retiring workspace id, if any.
    case handoffCompleted(reason: String, retiringWorkspaceId: UUID?)
}
