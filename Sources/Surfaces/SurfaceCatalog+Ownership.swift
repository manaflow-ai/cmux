import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Captures the authoritative identity, including Cloud resources still awaiting a provider.
    /// Pending remote identity takes precedence over a live local placeholder.
    func projectionRecord(forPanel panelID: UUID) -> SurfaceProjectionRecord? {
        guard let projection = pendingRestoredProjections.projection(forPanel: panelID)
            ?? projection(forPanel: panelID) else { return nil }
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
        pendingRestoredProjections.machineOwningPanel(panelID)
            ?? projection(forPanel: panelID)?.resource.machine
    }

    func validateOwnership(of resources: [SurfaceResourceID], at destination: SurfaceDestination) throws {
        let workspace = cloudWorkspaceRenameService.environment.workspace(destination.workspaceID)
            ?? Workspace.liveWorkspace(id: destination.workspaceID)
        if let policy = workspace?.surfaceOwnershipPolicy,
           let rejection = ownershipRejection(for: resources, policy: policy) { throw rejection }
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
