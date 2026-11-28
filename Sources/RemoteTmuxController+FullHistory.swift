import Foundation

@MainActor
extension RemoteTmuxController {
    /// The full-history load for the mirrored pane behind `surfaceId`, or nil when the
    /// surface is not a mirror pane.
    func fullHistorySearch(forSurfaceId surfaceId: UUID) -> RemoteTmuxFullHistorySearch? {
        for sessionMirror in sessionMirrors.values {
            if let paneId = sessionMirror.paneId(forSurfaceId: surfaceId) {
                return sessionMirror.fullHistorySearch(forPane: paneId)
            }
        }
        return nil
    }
}
