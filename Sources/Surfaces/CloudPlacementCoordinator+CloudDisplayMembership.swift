import CmuxCloud
import CmuxCloudTui
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
        // Fence the view before the asynchronous removal: reconciliation reads
        // the graph that still holds this token and would rebuild the pane.
        let machine = projection.resource.machine
        let clientID = CloudTuiClientPaths().notificationClientID()
        if let token = catalog.cloudStates[machine]?.displayMemberships.first(where: {
            $0.displayID == projection.resource.key
                && $0.clientID == clientID
                && $0.viewID == projection.panelID.uuidString.lowercased()
        }) {
            closedDisplayViews[machine, default: [:]][token.viewID] = token
        }
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

    /// Releases fenced display views whose token is gone from `state`, and
    /// retries the removal of any that are still present (a removal can fail
    /// silently while the link is down or after repeated revision conflicts).
    func settleClosedDisplayViews(_ state: CloudVMState, catalog: SurfaceCatalog) {
        guard var fenced = closedDisplayViews[state.machine], !fenced.isEmpty else { return }
        let present = Set(state.displayMemberships.map(\.viewID))
        for viewID in fenced.keys where !present.contains(viewID) {
            displayRemovalAttempts.removeValue(forKey: viewID)
        }
        fenced = fenced.filter { present.contains($0.key) }
        closedDisplayViews[state.machine] = fenced.isEmpty ? nil : fenced
        guard let provider = catalog.provider(for: state.machine) as? any CloudDisplayMembershipSyncing else { return }
        for token in fenced.values where !retryingDisplayRemovals.contains(token.viewID) {
            removeOrphanedDisplayMembership(token, provider: provider)
        }
    }

    /// Removes one of this Mac's membership tokens whose local view no longer
    /// exists. Used for a closed view whose removal has not landed and for a
    /// token the reconciler replaced with a newly materialized pane.
    func removeOrphanedDisplayMembership(
        _ token: CloudVMDisplayMembership,
        provider: any CloudDisplayMembershipSyncing
    ) {
        // Bounded: a token that never clears (for example one left in another
        // workspace by an old move) must not cost a guest write on every graph.
        guard let panelID = UUID(uuidString: token.viewID),
              displayRemovalAttempts[token.viewID, default: 0] < Self.maxDisplayRemovalAttempts,
              retryingDisplayRemovals.insert(token.viewID).inserted else { return }
        displayRemovalAttempts[token.viewID, default: 0] += 1
        Task { @MainActor [weak self] in
            defer { self?.retryingDisplayRemovals.remove(token.viewID) }
            try? await provider.syncCloudDisplayMembership(
                displayID: token.displayID,
                workspaceID: token.workspaceID,
                panelID: panelID,
                attached: false
            )
        }
    }
}
