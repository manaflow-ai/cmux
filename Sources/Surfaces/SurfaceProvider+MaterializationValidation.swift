import Foundation

extension SurfaceProvider {
    /// Checks the provider receipt before it can become a catalog projection.
    /// Cloud identity is not inferred from whatever pane happens to be selected
    /// when the asynchronous materialization finishes.
    func materializeValidated(
        _ resource: SurfaceResource,
        remoteView: SurfaceRemoteView?,
        at destination: SurfaceDestination,
        focus: Bool,
        adopting reservation: CloudTerminalPaneReservation?
    ) async throws -> SurfaceProjection {
        if let reservation { try reservation.sourcePlacement.validate(created: resource) }
        var projection = try await materialize(
            resource, remoteView: remoteView, at: destination, focus: focus, adopting: reservation
        )
        let expectedWorkspace = reservation?.remoteWorkspaceID
        if projection.remoteWorkspaceID == nil,
           let expectedWorkspace,
           resource.remoteWorkspace?.id == expectedWorkspace {
            // A valid create receipt may carry the authoritative workspace while
            // the daemon has not assigned a tab view yet. Preserve that identity
            // on the projection instead of treating it as a local placement.
            projection.remoteWorkspaceID = expectedWorkspace
        }
        guard projection.resource == resource.id,
              projection.workspaceID == destination.workspaceID,
              reservation == nil || remoteView == nil || projection.remoteTabID == remoteView?.tabID,
              expectedWorkspace == nil || projection.remoteWorkspaceID == expectedWorkspace else {
            if let reservation, projection.panelID == reservation.panelID {
                // Stop an adopted transport but retain the manual pane for its
                // failure card and explicit retry. No local replacement is born.
                projectionDidEnd(projection)
                reservation.inputRelay.discard()
            } else {
                discardMaterialization(projection)
            }
            throw CloudDiagnosticFailure.placement
        }
        return projection
    }
}
