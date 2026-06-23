#if DEBUG
import CmuxFoundation

public extension PendingWorkspaceUnfocusEvent {
    /// The byte-identical legacy `ws.unfocus.*` debug trace line for this event.
    ///
    /// Pure string assembly lifted verbatim from the app-target
    /// `TabManager.logPendingWorkspaceUnfocusEvent(_:)`: the `defer` and
    /// `complete` cases prepend the in-flight switch `id=<id> dt=<ms>` prefix
    /// when a snapshot is present (else `id=none`); the `flush`/`drop` cases
    /// carry no snapshot prefix. The window host computes the elapsed
    /// milliseconds and passes the snapshot, then emits this line through
    /// `cmuxDebugLog`. `#if DEBUG`-only, mirroring the original guarded calls.
    ///
    /// - Parameters:
    ///   - snapshot: The in-flight workspace-switch trace snapshot, or `nil`
    ///     when no switch is active (selects the legacy `id=none` branch).
    ///   - elapsedMs: The elapsed milliseconds since the switch started, used
    ///     only when `snapshot` is non-`nil`.
    /// - Returns: The formatted `ws.unfocus.*` trace line.
    func traceLine(switchSnapshot snapshot: WorkspaceSwitchTraceSnapshot?, elapsedMs: Double?) -> String {
        switch self {
        case let .deferred(workspaceId, panelId):
            if let snapshot, let elapsedMs {
                return "ws.unfocus.defer id=\(snapshot.id) dt=\(elapsedMs.debugMillisecondsText) " +
                    "tab=\(workspaceId.debugShortWorkspaceId) panel=\(String(panelId.uuidString.prefix(5)))"
            } else {
                return "ws.unfocus.defer id=none tab=\(workspaceId.debugShortWorkspaceId) panel=\(String(panelId.uuidString.prefix(5)))"
            }
        case let .flushedOnReplace(workspaceId, panelId):
            return "ws.unfocus.flush tab=\(workspaceId.debugShortWorkspaceId) panel=\(String(panelId.uuidString.prefix(5))) reason=replaced"
        case let .droppedOnReplaceSelected(workspaceId, panelId):
            return "ws.unfocus.drop tab=\(workspaceId.debugShortWorkspaceId) panel=\(String(panelId.uuidString.prefix(5))) reason=replaced_selected"
        case let .droppedSelectedAgain(workspaceId, panelId):
            return "ws.unfocus.drop tab=\(workspaceId.debugShortWorkspaceId) panel=\(String(panelId.uuidString.prefix(5))) reason=selected_again"
        case let .completed(workspaceId, panelId, reason):
            if let snapshot, let elapsedMs {
                return "ws.unfocus.complete id=\(snapshot.id) dt=\(elapsedMs.debugMillisecondsText) " +
                    "tab=\(workspaceId.debugShortWorkspaceId) panel=\(String(panelId.uuidString.prefix(5))) reason=\(reason)"
            } else {
                return "ws.unfocus.complete id=none tab=\(workspaceId.debugShortWorkspaceId) " +
                    "panel=\(String(panelId.uuidString.prefix(5))) reason=\(reason)"
            }
        }
    }
}
#endif
