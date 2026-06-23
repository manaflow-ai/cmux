public import Foundation

/// Pending controlling-terminal (TTY) and port-scan-kick bookkeeping for the
/// surface coordinator.
///
/// A remote surface's TTY name and the port-scan kick that should follow it
/// often arrive (over the control stream / bootstrap) before the surface that
/// owns them is tracked. These methods stash the pending value on ``state`` and
/// apply it once the matching surface is tracked. Faithful lift of the
/// `Workspace` pending-TTY/port-kick methods.
extension RemoteSurfaceCoordinator {
    /// Remembers a controlling-terminal name to apply to the next tracked remote
    /// surface (or `requestedSurfaceId` when given). Faithful lift of
    /// `Workspace.rememberPendingRemoteSurfaceTTY(_:requestedSurfaceId:)`.
    public func rememberPendingRemoteSurfaceTTY(_ ttyName: String, requestedSurfaceId: UUID?) {
        let trimmedTTY = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTTY.isEmpty else { return }
        state.pendingRemoteSurfaceTTYName = trimmedTTY
        state.pendingRemoteSurfaceTTYSurfaceId = requestedSurfaceId
    }

    /// Remembers a port-scan kick reason to apply to the next tracked remote
    /// surface (or `requestedSurfaceId` when given). Faithful lift of
    /// `Workspace.rememberPendingRemoteSurfacePortKick(reason:requestedSurfaceId:)`.
    public func rememberPendingRemoteSurfacePortKick(
        reason: PortScanKickReason,
        requestedSurfaceId: UUID?
    ) {
        state.pendingRemoteSurfacePortKickReason = reason
        state.pendingRemoteSurfacePortKickSurfaceId = requestedSurfaceId
    }

    /// Applies any pending TTY name to `panelId` (when it is the requested
    /// surface or none was requested), then syncs the scan TTYs and kicks a
    /// scan. Faithful lift of `Workspace.applyPendingRemoteSurfaceTTYIfNeeded(to:)`.
    public func applyPendingRemoteSurfaceTTYIfNeeded(to panelId: UUID) {
        guard let host,
              let ttyName = state.pendingRemoteSurfaceTTYName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return
        }
        if let requestedSurfaceId = state.pendingRemoteSurfaceTTYSurfaceId, requestedSurfaceId != panelId {
            return
        }
        host.hostSetSurfaceTTYName(ttyName, for: panelId)
        state.pendingRemoteSurfaceTTYName = nil
        state.pendingRemoteSurfaceTTYSurfaceId = nil
        syncRemotePortScanTTYs()
        if !applyPendingRemoteSurfacePortKickIfNeeded(to: panelId) {
            kickRemotePortScan(panelId: panelId, reason: .command)
        }
    }

    /// Applies any pending port-scan kick to `panelId` once its TTY is known.
    /// Returns whether a kick was applied. Faithful lift of
    /// `Workspace.applyPendingRemoteSurfacePortKickIfNeeded(to:)`.
    @discardableResult
    public func applyPendingRemoteSurfacePortKickIfNeeded(to panelId: UUID) -> Bool {
        guard let host, let reason = state.pendingRemoteSurfacePortKickReason else {
            return false
        }
        if let requestedSurfaceId = state.pendingRemoteSurfacePortKickSurfaceId,
           requestedSurfaceId != panelId {
            return false
        }
        guard let ttyName = host.hostSurfaceTTYName(panelId)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return false
        }
        _ = ttyName
        state.pendingRemoteSurfacePortKickReason = nil
        state.pendingRemoteSurfacePortKickSurfaceId = nil
        kickRemotePortScan(panelId: panelId, reason: reason)
        return true
    }

    /// Applies a bootstrap controlling-terminal name to the focused (or sole)
    /// active remote surface, stashing it pending when no candidate exists.
    /// Faithful lift of `Workspace.applyBootstrapRemoteTTY(_:)`.
    public func applyBootstrapRemoteTTY(_ ttyName: String) {
        guard let host else { return }
        let trimmedTTY = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTTY.isEmpty else { return }

        let candidateSurfaceId: UUID? = {
            if let focusedPanelId = host.hostFocusedPanelId,
               state.activeRemoteTerminalSurfaceIds.contains(focusedPanelId) {
                return focusedPanelId
            }
            if state.activeRemoteTerminalSurfaceIds.count == 1 {
                return state.activeRemoteTerminalSurfaceIds.first
            }
            return nil
        }()

        guard let candidateSurfaceId else {
            rememberPendingRemoteSurfaceTTY(trimmedTTY, requestedSurfaceId: nil)
            return
        }

        host.hostSetSurfaceTTYName(trimmedTTY, for: candidateSurfaceId)
        syncRemotePortScanTTYs()
        if !applyPendingRemoteSurfacePortKickIfNeeded(to: candidateSurfaceId) {
            kickRemotePortScan(panelId: candidateSurfaceId, reason: .command)
        }
    }
}
