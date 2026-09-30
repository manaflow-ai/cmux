import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

extension CloudPlacementCoordinator {
    /// Writes the durable membership after the local pane has been admitted.
    /// The lane serializes a move's detach and attach so a revision update cannot
    /// publish a half-moved display view.
    func syncCloudDisplayMembership(
        projection: SurfaceProjection,
        catalog: SurfaceCatalog
    ) {
        guard projection.resource.kind == .display,
              let provider = catalog.provider(for: projection.resource.machine) as? any CloudDisplayMembershipSyncing
        else { return }
        enqueue(projection, catalog: catalog, presentFailure: false) {
            guard let latest = catalog.projection(forPanel: projection.panelID),
                  latest.resource == projection.resource else { return false }
            let old = try await provider.cloudDisplayMembershipWorkspace(
                displayID: projection.resource.key,
                panelID: projection.panelID
            )
            let next = latest.remoteWorkspaceID
            var attachedNext = false
            if let old, old != next {
                // Each workspace has its own projection row, so a move cannot
                // be one backend transaction. Attach first to keep the old
                // placement live if the new write fails; compensate on a
                // failed detach so a transient move never loses membership.
                if let next {
                    try await provider.syncCloudDisplayMembership(
                        displayID: projection.resource.key,
                        workspaceID: next,
                        panelID: projection.panelID,
                        attached: true
                    )
                    attachedNext = true
                }
                do {
                    try await provider.syncCloudDisplayMembership(
                        displayID: projection.resource.key,
                        workspaceID: old,
                        panelID: projection.panelID,
                        attached: false
                    )
                } catch {
                    if let next {
                        try? await provider.syncCloudDisplayMembership(
                            displayID: projection.resource.key,
                            workspaceID: next,
                            panelID: projection.panelID,
                            attached: false
                        )
                    }
                    throw error
                }
            }
            if let next, !attachedNext {
                try await provider.syncCloudDisplayMembership(
                    displayID: projection.resource.key,
                    workspaceID: next,
                    panelID: projection.panelID,
                    attached: true
                )
            }
            return old != next || attachedNext
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
              let provider = catalog.provider(for: projection.resource.machine) as? any CloudDisplayMembershipSyncing else { return }
        enqueue(projection, catalog: catalog, presentFailure: false) {
            guard let workspaceID = try await provider.cloudDisplayMembershipWorkspace(
                displayID: projection.resource.key,
                panelID: projection.panelID
            ) else { return false }
            try await provider.syncCloudDisplayMembership(
                displayID: projection.resource.key,
                workspaceID: workspaceID,
                panelID: projection.panelID,
                attached: false
            )
            return true
        }
    }
}
