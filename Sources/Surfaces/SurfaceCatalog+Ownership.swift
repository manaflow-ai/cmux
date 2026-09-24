import Foundation

extension SurfaceCatalog {
    /// The staged restore identity owns a placeholder until its provider materializes it.
    /// Retains workspace coordinates so routing can validate ownership in the same read.
    func projectionIncludingPendingRestore(forPanel panelID: UUID) -> SurfaceProjection? {
        pendingRestoredProjections.projection(forPanel: panelID) ?? projection(forPanel: panelID)
    }

    /// Captures the authoritative identity, including Cloud resources still awaiting a provider.
    /// Pending remote identity takes precedence over a live local placeholder.
    func projectionRecord(forPanel panelID: UUID) -> SurfaceProjectionRecord? {
        guard let projection = projectionIncludingPendingRestore(forPanel: panelID) else { return nil }
        return SurfaceProjectionRecord(
            panelID: panelID,
            resource: projection.resource,
            remoteWorkspaceID: projection.remoteWorkspaceID,
            remoteTabID: projection.remoteTabID
        )
    }

    /// Only a provider's remote materialization supersedes a pending Cloud identity.
    /// The local shell/browser registered during restore is still its placeholder.
    func consumePendingProjectionIfMaterialized(_ projection: SurfaceProjection) {
        if !projection.resource.machine.isLocal {
            pendingRestoredProjections.remove(panelID: projection.panelID)
        }
    }

    func projection(forPanel panelID: UUID) -> SurfaceProjection? {
        projections.first { $0.panelID == panelID }
    }


    /// Restored projections retain their owner even before the provider reconnects.
    func machineOwningPanel(_ panelID: UUID) -> SurfaceMachineID? {
        projectionIncludingPendingRestore(forPanel: panelID)?.resource.machine
    }

    func validateOwnership(of resources: [SurfaceResourceID], at destination: SurfaceDestination) throws {
        guard let workspace = cloudWorkspaceRenameService.environment.workspace(destination.workspaceID)
                ?? Workspace.liveWorkspace(id: destination.workspaceID) else {
            throw SurfaceCatalogError.destinationNotFound(destination.workspaceID.uuidString)
        }
        if let rejection = ownershipRejection(for: resources, policy: workspace.surfaceOwnershipPolicy) {
            throw rejection
        }
    }

    /// Provider work may suspend. Check the live destination again before its
    /// receipt can enter the catalog, and retire only the just-created view.
    func validateMaterializationOwnership(_ projection: SurfaceProjection, provider: any SurfaceProvider) throws {
        do {
            if DockSplitStore.liveStore(containingPanel: projection.panelID)?.scope == .global {
                return
            }
            try validateOwnership(of: [projection.resource], at: .workspace(id: projection.workspaceID, placement: .tab))
        } catch {
            provider.discardMaterialization(projection)
            throw error
        }
    }

    func canRestoreProjection(_ projection: SurfaceProjection) -> Bool {
        if DockSplitStore.liveStore(containingPanel: projection.panelID)?.scope == .global {
            return true
        }
        do {
            try validateOwnership(of: [projection.resource], at: .workspace(id: projection.workspaceID, placement: .tab))
            return true
        } catch {
            return false
        }
    }

    func ownershipRejection(for resources: [SurfaceResourceID], policy: SurfaceOwnershipPolicy) -> SurfaceTransferRejection? {
        guard policy.cloudMachine != nil else { return nil }
        return policy.rejection(for: resources.map(machineOwningResource))
    }

    /// A legacy SSH projection is catalogued by its local PTY, while the live
    /// panel retains the stable Cloud machine that actually executes its shell.
    private func machineOwningResource(_ resource: SurfaceResourceID) -> SurfaceMachineID {
        guard resource.machine.isLocal, let panelID = UUID(uuidString: resource.key) else { return resource.machine }
        if let dock = DockSplitStore.liveStore(containingPanel: panelID) {
            return dock.machineOwningSurface(panelID) ?? resource.machine
        }
        if let projection = projection(forPanel: panelID),
           let workspace = cloudWorkspaceRenameService.environment.workspace(projection.workspaceID)
                ?? Workspace.liveWorkspace(id: projection.workspaceID),
           let machine = workspace.machineOwningSurface(panelID, catalog: self) {
            return machine
        }
        return AppDelegate.shared?.workspace(containingSurfaceID: panelID)?.machineOwningSurface(panelID, catalog: self)
            ?? resource.machine
    }
}
