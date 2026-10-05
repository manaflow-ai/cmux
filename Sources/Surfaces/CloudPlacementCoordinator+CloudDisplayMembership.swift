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
        ownedDisplayViewIDs.insert(projection.panelID.uuidString.lowercased())
        if let workspaceID = projection.remoteWorkspaceID {
            // A pane of this display opened here again: the display is back in
            // the workspace, so its earlier removal no longer applies.
            let closed = ClosedCloudDisplay(projection: projection, workspaceID: workspaceID)
            closedDisplays.remove(closed)
            closedDisplayRemovalAttempts[closed] = nil
        }
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

    /// Closing a display pane removes the display from its Cloud workspace for
    /// every client, as closing a terminal tab does. Another client's token
    /// would otherwise rebuild the pane on the next graph.
    func syncCloudDisplayMembershipEnd(
        projection: SurfaceProjection,
        reason: SurfaceProjectionEndReason,
        catalog: SurfaceCatalog
    ) {
        guard reason == .paneClosed,
              projection.resource.kind == .display,
              let provider = catalog.provider(for: projection.resource.machine) as? any CloudDisplayMembershipSyncing else { return }
        // Fence before any I/O, from the pane's own workspace: reconciliation
        // reads a graph that may still hold (or not yet hold) a token for it.
        let known = projection.remoteWorkspaceID
            ?? boundRemoteWorkspaceID(forLocalWorkspace: projection.workspaceID, on: projection.resource.machine)
        if let known { closedDisplays.insert(ClosedCloudDisplay(projection: projection, workspaceID: known)) }
        enqueue(projection, catalog: catalog, presentFailure: false) { [weak self] in
            // The token can name a workspace the pane was moved out of.
            let recorded = try? await provider.cloudDisplayMembershipWorkspace(
                displayID: projection.resource.key,
                panelID: projection.panelID
            )
            let workspaces = Set([known, recorded].compactMap { $0 })
            guard !workspaces.isEmpty else { return false }
            for workspaceID in workspaces {
                self?.closedDisplays.insert(ClosedCloudDisplay(projection: projection, workspaceID: workspaceID))
                try await provider.removeCloudDisplay(displayID: projection.resource.key, fromWorkspace: workspaceID)
            }
            return true
        }
    }

    /// The sidebar's X on a display in a Cloud workspace. With a pane of it
    /// here, closing that pane is the removal; otherwise the membership is
    /// removed directly.
    func removeDisplay(_ resource: SurfaceResourceID, fromCloudWorkspace workspaceID: String, catalog: SurfaceCatalog) {
        guard resource.kind == .display,
              let provider = catalog.provider(for: resource.machine) as? any CloudDisplayMembershipSyncing else { return }
        let closed = ClosedCloudDisplay(machine: resource.machine, workspaceID: workspaceID, displayID: resource.key)
        closedDisplays.insert(closed)
        let panes = catalog.projections.filter { $0.resource == resource && $0.remoteWorkspaceID == workspaceID }
        for pane in panes {
            _ = Workspace.liveWorkspace(id: pane.workspaceID)?.closePanel(pane.panelID, force: true)
        }
        if panes.isEmpty { removeClosedDisplay(closed, provider: provider) }
    }

    /// Releases closed displays whose membership is gone from `state`, and
    /// retries the removal of any still present (a removal can fail while the
    /// link is down or after repeated revision conflicts).
    func settleClosedDisplays(_ state: CloudVMState, catalog: SurfaceCatalog) {
        let fenced = closedDisplays.filter { $0.machine == state.machine }
        guard !fenced.isEmpty else { return }
        let present = Set(state.displayMemberships.map {
            ClosedCloudDisplay(machine: state.machine, workspaceID: $0.workspaceID, displayID: $0.displayID)
        })
        for closed in fenced where !present.contains(closed) {
            closedDisplays.remove(closed)
            closedDisplayRemovalAttempts[closed] = nil
        }
        guard let provider = catalog.provider(for: state.machine) as? any CloudDisplayMembershipSyncing else { return }
        for closed in fenced where present.contains(closed) {
            removeClosedDisplay(closed, provider: provider)
        }
    }

    /// Bounded: a membership that never clears must not cost a guest write on
    /// every graph. A machine that cannot take the write yet (asleep) does not
    /// spend an attempt.
    private func removeClosedDisplay(_ closed: ClosedCloudDisplay, provider: any CloudDisplayMembershipSyncing) {
        guard closedDisplayRemovalAttempts[closed, default: 0] < Self.maxDisplayRemovalAttempts,
              closedDisplayRemovalsInFlight.insert(closed).inserted else { return }
        Task { @MainActor [weak self] in
            defer { self?.closedDisplayRemovalsInFlight.remove(closed) }
            do {
                try await provider.removeCloudDisplay(displayID: closed.displayID, fromWorkspace: closed.workspaceID)
            } catch {
                guard !Self.isTransientDisplayMembershipFailure(error) else { return }
            }
            self?.closedDisplayRemovalAttempts[closed, default: 0] += 1
        }
    }

    /// Removes one of this process's membership tokens whose local view no
    /// longer exists: a token the reconciler replaced with a newly
    /// materialized pane, or one left by a pane that is gone.
    func removeOrphanedDisplayMembership(
        _ token: CloudVMDisplayMembership,
        provider: any CloudDisplayMembershipSyncing
    ) {
        // Bounded: a token that never clears (for example one left in another
        // workspace by an old move) must not cost a guest write on every graph.
        guard let panelID = UUID(uuidString: token.viewID),
              displayRemovalAttempts[token.viewID, default: 0] < Self.maxDisplayRemovalAttempts,
              retryingDisplayRemovals.insert(token.viewID).inserted else { return }
        Task { @MainActor [weak self] in
            defer { self?.retryingDisplayRemovals.remove(token.viewID) }
            do {
                try await provider.syncCloudDisplayMembership(
                    displayID: token.displayID,
                    workspaceID: token.workspaceID,
                    panelID: panelID,
                    attached: false
                )
            } catch {
                // Before discovery publishes the display, or while the machine
                // sleeps, the write cannot happen yet; that is not an attempt.
                guard !Self.isTransientDisplayMembershipFailure(error) else { return }
            }
            self?.displayRemovalAttempts[token.viewID, default: 0] += 1
        }
    }

    private static func isTransientDisplayMembershipFailure(_ error: Error) -> Bool {
        if let error = error as? SurfaceCatalogError, case .unknownResource = error { return true }
        if let error = error as? CmuxTuiSurfaceProvider.ProviderError, case .machineAsleep = error { return true }
        return false
    }
}

/// One display in one Cloud workspace on one machine.
struct ClosedCloudDisplay: Hashable {
    let machine: SurfaceMachineID
    let workspaceID: String
    let displayID: String
}

extension ClosedCloudDisplay {
    init(projection: SurfaceProjection, workspaceID: String) {
        self.init(machine: projection.resource.machine, workspaceID: workspaceID, displayID: projection.resource.key)
    }
}
