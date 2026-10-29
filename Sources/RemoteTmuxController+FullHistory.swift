import Foundation

@MainActor
extension RemoteTmuxController {
    /// Repaints the mirrored pane behind `surfaceId` with its whole tmux history.
    ///
    /// `.failed` when the surface is not a connected mirror pane.
    func reseedFullHistory(forSurfaceId surfaceId: UUID) async -> RemoteTmuxFullHistorySeedOutcome {
        for sessionMirror in sessionMirrors.values where sessionMirror.connection.connectionState == .connected {
            if let paneId = sessionMirror.paneId(forSurfaceId: surfaceId) {
                return await sessionMirror.connection.reseedPaneWithFullHistory(paneId: paneId)
            }
        }
        return .failed
    }
}
