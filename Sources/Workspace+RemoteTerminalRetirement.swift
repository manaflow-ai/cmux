import Foundation

extension Workspace {
    /// Retires a process generation while retaining logical membership for a replacement.
    func retireRemoteTerminalLifecycle(
        panelId: UUID,
        preservesRemoteTerminalTracking: Bool,
        closesPanel: Bool
    ) {
        if preservesRemoteTerminalTracking {
            // A replacement keeps the logical remote surface alive while its
            // old process generation and panel object are discarded.
            clearRemoteTerminalSessionPhase(surfaceId: panelId)
        } else {
            untrackRemoteTerminalSurface(panelId)
        }
        if closesPanel {
            endedRemoteTerminalLifecycleIDsBySurfaceId.removeValue(forKey: panelId)
        }
        discardRemoteDirectoryTrustState(panelId: panelId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
    }
}
