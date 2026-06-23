#if DEBUG
import CmuxFoundation

public extension WorkspaceHandoffEvent {
    /// The byte-identical legacy `ws.mount.reconcile` / `ws.handoff.*` debug
    /// trace line for this event.
    ///
    /// Pure string assembly lifted verbatim from the app-target
    /// `TabManager.logWorkspaceHandoffEvent(_:)`: every case prepends the
    /// in-flight switch `id=<id> dt=<ms>` prefix when a snapshot is present
    /// (else the abbreviated `id=none` branch). The window host computes the
    /// elapsed milliseconds and passes the snapshot, then emits this line
    /// through `cmuxDebugLog`. `#if DEBUG`-only, mirroring the original guarded
    /// calls.
    ///
    /// - Parameters:
    ///   - snapshot: The in-flight workspace-switch trace snapshot, or `nil`
    ///     when no switch is active (selects the legacy `id=none` branch).
    ///   - elapsedMs: The elapsed milliseconds since the switch started, used
    ///     only when `snapshot` is non-`nil`.
    /// - Returns: The formatted `ws.mount.reconcile` / `ws.handoff.*` trace line.
    func traceLine(switchSnapshot snapshot: WorkspaceSwitchTraceSnapshot?, elapsedMs: Double?) -> String {
        switch self {
        case let .mountReconciled(isCycleHot, selectedWorkspaceId, mountedWorkspaceIds, addedWorkspaceIds, removedWorkspaceIds):
            if let snapshot, let elapsedMs {
                return "ws.mount.reconcile id=\(snapshot.id) dt=\(elapsedMs.debugMillisecondsText) hot=\(isCycleHot ? 1 : 0) " +
                    "selected=\(selectedWorkspaceId.debugShortWorkspaceId) " +
                    "mounted=\(mountedWorkspaceIds.debugShortWorkspaceIds) " +
                    "added=\(addedWorkspaceIds.debugShortWorkspaceIds) removed=\(removedWorkspaceIds.debugShortWorkspaceIds)"
            } else {
                return "ws.mount.reconcile id=none hot=\(isCycleHot ? 1 : 0) selected=\(selectedWorkspaceId.debugShortWorkspaceId) " +
                    "mounted=\(mountedWorkspaceIds.debugShortWorkspaceIds)"
            }
        case let .handoffStarted(oldSelectedWorkspaceId, newSelectedWorkspaceId):
            if let snapshot, let elapsedMs {
                return "ws.handoff.start id=\(snapshot.id) dt=\(elapsedMs.debugMillisecondsText) old=\(oldSelectedWorkspaceId.debugShortWorkspaceId) " +
                    "new=\(newSelectedWorkspaceId.debugShortWorkspaceId)"
            } else {
                return "ws.handoff.start id=none old=\(oldSelectedWorkspaceId.debugShortWorkspaceId) new=\(newSelectedWorkspaceId.debugShortWorkspaceId)"
            }
        case let .handoffFastReady(selectedWorkspaceId):
            if let snapshot, let elapsedMs {
                return "ws.handoff.fastReady id=\(snapshot.id) dt=\(elapsedMs.debugMillisecondsText) selected=\(selectedWorkspaceId.debugShortWorkspaceId)"
            } else {
                return "ws.handoff.fastReady id=none selected=\(selectedWorkspaceId.debugShortWorkspaceId)"
            }
        case let .handoffCompleted(reason, retiringWorkspaceId):
            if let snapshot, let elapsedMs {
                return "ws.handoff.complete id=\(snapshot.id) dt=\(elapsedMs.debugMillisecondsText) reason=\(reason) retiring=\(retiringWorkspaceId.debugShortWorkspaceId)"
            } else {
                return "ws.handoff.complete id=none reason=\(reason) retiring=\(retiringWorkspaceId.debugShortWorkspaceId)"
            }
        }
    }
}
#endif
