import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

extension CloudPlacementCoordinator {
    /// Writes the durable membership after the local pane has been admitted.
    /// The lane serializes a move's detach and attach so a revision update cannot
    /// publish a half-moved display view.
    func syncCloudDisplayMembership(
        projection: SurfaceProjection,
        current: SurfaceProjection,
        catalog: SurfaceCatalog
    ) {
        guard projection.resource.kind == .display,
              let provider = catalog.provider(for: projection.resource.machine) as? any CloudDisplayMembershipSyncing
        else { return }
        let previous = localDisplayMemberships[projection.panelID]
        let target = current.remoteWorkspaceID
        guard previous != target || (previous == nil && target != nil) else { return }
        enqueue(projection, catalog: catalog, presentFailure: false) {
            guard let latest = catalog.projection(forPanel: projection.panelID),
                  latest.resource == projection.resource else { return false }
            let old = self.localDisplayMemberships[projection.panelID]
            let next = latest.remoteWorkspaceID
            if let old, old != next {
                try await provider.syncCloudDisplayMembership(
                    displayID: projection.resource.key,
                    workspaceID: old,
                    panelID: projection.panelID,
                    attached: false
                )
            }
            if let next {
                try await provider.syncCloudDisplayMembership(
                    displayID: projection.resource.key,
                    workspaceID: next,
                    panelID: projection.panelID,
                    attached: true
                )
                self.localDisplayMemberships[projection.panelID] = next
            } else {
                self.localDisplayMemberships[projection.panelID] = nil
            }
            return true
        }
    }

    /// Removes only this local view's durable token. Other clients and other
    /// views retain their membership in the shared projection.
    func syncCloudDisplayMembershipEnd(
        projection: SurfaceProjection,
        reason: SurfaceProjectionEndReason,
        catalog: SurfaceCatalog
    ) {
        guard reason == .paneClosed,
              projection.resource.kind == .display,
              let workspaceID = localDisplayMemberships[projection.panelID]
                  ?? projection.remoteWorkspaceID,
              let provider = catalog.provider(for: projection.resource.machine) as? any CloudDisplayMembershipSyncing,
              !catalog.projections.contains(where: {
                  $0.panelID != projection.panelID
                      && $0.resource == projection.resource
                      && $0.remoteWorkspaceID == workspaceID
                      && $0.isLocalWorkspaceView
              }) else { return }
        enqueue(projection, catalog: catalog, presentFailure: false) {
            try await provider.syncCloudDisplayMembership(
                displayID: projection.resource.key,
                workspaceID: workspaceID,
                panelID: projection.panelID,
                attached: false
            )
            self.localDisplayMemberships[projection.panelID] = nil
            return true
        }
    }
}
