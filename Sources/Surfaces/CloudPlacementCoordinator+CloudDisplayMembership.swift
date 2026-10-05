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
        // A pane of this display opened here again: it is back in its
        // workspace, and a close or retry already queued must not undo that.
        displayReopenGenerations[projection.resource, default: 0] += 1
        if let workspaceID = projection.remoteWorkspaceID {
            closedDisplays[ClosedCloudDisplay(projection: projection, workspaceID: workspaceID)] = nil
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
        if let known { fence(ClosedCloudDisplay(projection: projection, workspaceID: known)) }
        let generation = displayReopenGenerations[projection.resource, default: 0]
        enqueue(projection, catalog: catalog, presentFailure: false) { [weak self] in
            // The token can name a workspace the pane was moved out of.
            let recorded = try? await provider.cloudDisplayMembershipWorkspace(
                displayID: projection.resource.key,
                panelID: projection.panelID
            )
            let workspaces = Set([known, recorded].compactMap { $0 })
            guard !workspaces.isEmpty else { return false }
            for workspaceID in workspaces {
                guard let self, self.displayReopenGenerations[projection.resource, default: 0] == generation else { return true }
                let closed = ClosedCloudDisplay(projection: projection, workspaceID: workspaceID)
                self.fence(closed)
                let removed = try await provider.removeCloudDisplay(displayID: closed.displayID, fromWorkspace: workspaceID)
                self.closedDisplays[closed]?.removed = removed
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
        fence(closed)
        let panes = catalog.projections.filter { $0.resource == resource && $0.remoteWorkspaceID == workspaceID }
        for pane in panes {
            _ = Workspace.liveWorkspace(id: pane.workspaceID)?.closePanel(pane.panelID, force: true)
        }
        if panes.isEmpty { removeClosedDisplay(closed, provider: provider, catalog: catalog) }
    }

    private func fence(_ closed: ClosedCloudDisplay) {
        if closedDisplays[closed] == nil { closedDisplays[closed] = ClosedCloudDisplayRemoval() }
    }

    /// Releases a closed display once the graph no longer shows it, or shows a
    /// membership its removal did not delete (another client put it back).
    /// A graph holding only deleted tokens predates the removal. A removal
    /// that has not landed is retried.
    func settleClosedDisplays(_ state: CloudVMState, catalog: SurfaceCatalog) {
        let fenced = closedDisplays.filter { $0.key.machine == state.machine }
        guard !fenced.isEmpty else { return }
        let provider = catalog.provider(for: state.machine) as? any CloudDisplayMembershipSyncing
        for (closed, removal) in fenced {
            let present = Set(state.displayMemberships.filter {
                $0.workspaceID == closed.workspaceID && $0.displayID == closed.displayID
            })
            if let removed = removal.removed {
                if !present.isSubset(of: removed) || present.isEmpty { closedDisplays[closed] = nil }
            } else if present.isEmpty {
                closedDisplays[closed] = nil
            } else if let provider {
                removeClosedDisplay(closed, provider: provider, catalog: catalog)
            }
        }
    }

    /// Bounded: a membership that never clears must not cost a guest write on
    /// every graph. Runs on the machine's lane, so it is ordered against a
    /// reopen's attach; a machine that cannot take the write yet (asleep) does
    /// not spend an attempt.
    private func removeClosedDisplay(
        _ closed: ClosedCloudDisplay,
        provider: any CloudDisplayMembershipSyncing,
        catalog: SurfaceCatalog
    ) {
        guard let removal = closedDisplays[closed], !removal.retrying,
              removal.attempts < Self.maxDisplayRemovalAttempts else { return }
        closedDisplays[closed]?.retrying = true
        let resource = SurfaceResourceID(machine: closed.machine, kind: .display, key: closed.displayID)
        let generation = displayReopenGenerations[resource, default: 0]
        enqueue(resource: resource, catalog: catalog) { [weak self] in
            defer { self?.closedDisplays[closed]?.retrying = false }
            guard let self, self.closedDisplays[closed] != nil,
                  self.displayReopenGenerations[resource, default: 0] == generation else { return false }
            do {
                let removed = try await provider.removeCloudDisplay(displayID: closed.displayID, fromWorkspace: closed.workspaceID)
                self.closedDisplays[closed]?.removed = removed
            } catch {
                if !Self.isTransientDisplayMembershipFailure(error) { self.closedDisplays[closed]?.attempts += 1 }
                throw error
            }
            return true
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

/// Progress of removing a closed display from its workspace.
struct ClosedCloudDisplayRemoval: Equatable {
    /// The tokens the landed removal deleted; nil until it lands.
    var removed: Set<CloudVMDisplayMembership>?
    var attempts = 0
    var retrying = false
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
