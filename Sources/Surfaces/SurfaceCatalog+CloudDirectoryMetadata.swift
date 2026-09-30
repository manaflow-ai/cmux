import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Returns the last accepted cwd for a stale Cloud terminal, when its identity still exists.
    ///
    /// A stale graph is useful display state, but a resource row can also contain an optimistic
    /// requested cwd. Read the cached value from the accepted graph so that a request, a retired
    /// provider, or a resource whose identity disappeared cannot become a displayed path.
    private func acceptedStaleCloudDirectory(for resource: SurfaceResource) -> String? {
        guard resource.kind == .terminal,
              resource.machine.tuiMachineID != nil,
              cloudStateObservations[resource.machine]?.freshness == .stale,
              let directory = cloudStates[resource.machine]?.lookupIndex.terminal(id: resource.id.key)?.cwd else {
            return nil
        }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Retain stale graphs for diagnostics while presenting a previously accepted cwd as a
    /// cached value. A requested launch directory or a stale graph with no accepted cwd remains
    /// unavailable.
    func resourceForPresentation(_ resource: SurfaceResource) -> SurfaceResource {
        // Cloud VM freshness is tracked in `cloudStateObservations`; device
        // mirrors receive their directory from the synced workspace record and
        // intentionally have no CloudVM observation to consult.
        guard resource.kind == .terminal, resource.machine.tuiMachineID != nil else { return resource }
        guard cloudStateObservations[resource.machine]?.freshness != .current else { return resource }
        var result = resource
        result.detail = acceptedStaleCloudDirectory(for: resource)
        return result
    }

    /// Projects accepted directory and machine metadata independently from name reconciliation.
    /// The catalog remains authoritative; Workspace owns only the UI-facing projection.
    func updateCloudDirectoryMetadata(on machine: SurfaceMachineID, affectedResourceIDs: Set<SurfaceResourceID>? = nil) {
        let projectedWorkspaceIDs = Set(projections.filter {
            $0.resource.machine == machine && (affectedResourceIDs?.contains($0.resource) ?? true)
        }.map(\.workspaceID))
        if let affectedResourceIDs {
            for id in projectedWorkspaceIDs {
                guard let workspace = cloudWorkspaceRenameService.environment.workspace(id) else { continue }
                updateCloudDirectoryMetadata(in: workspace, affectedResourceIDs: affectedResourceIDs)
            }
            return
        }
        for workspace in cloudWorkspaceRenameService.environment.workspaces()
            where (machine.tuiMachineID != nil && workspace.cloudVMBinding?.vmID == machine.tuiMachineID) || projectedWorkspaceIDs.contains(workspace.id)
                || workspace.cloudBindingState.projectedResources.values.contains(where: { $0.machine == machine }) {
            updateCloudDirectoryMetadata(in: workspace)
        }
    }

    func updateCloudDirectoryMetadata(localWorkspaceID: UUID) {
        guard let workspace = cloudWorkspaceRenameService.environment.workspace(localWorkspaceID) else { return }
        updateCloudDirectoryMetadata(in: workspace)
    }

    private func updateCloudDirectoryMetadata(in workspace: Workspace, affectedResourceIDs: Set<SurfaceResourceID>? = nil) {
        // Saved projections establish ownership even before their provider rediscovers the resource.
        let projected = projectionRecords(forWorkspace: workspace.id).filter { !$0.resource.machine.isLocal }
        let resourcesByPanel = Dictionary(projected.map { ($0.panelID, $0.resource) }, uniquingKeysWith: { first, _ in first })
        var machineIDs = Set(projected.map { $0.resource.machine.rawValue })
        if let id = workspace.cloudVMID { machineIDs.insert(id) }
        let names = Dictionary(uniqueKeysWithValues: machineIDs.map { id in
            (id, machines[SurfaceMachineID(rawValue: id)]?.name ?? id)
        })
        let previous = workspace.cloudBindingState.projectedResources
        workspace.cloudBindingState.updateCatalogMetadata(resources: resourcesByPanel, machineNames: names)
        for panelID in previous.keys where resourcesByPanel[panelID] == nil && workspace.panels[panelID] != nil {
            workspace.clearRemotePanelDirectory(panelId: panelID)
        }
        for projection in projected where workspace.panels[projection.panelID] != nil {
            if let affectedResourceIDs, !affectedResourceIDs.contains(projection.resource) { continue }
            let machine = projection.resource.machine
            let resource = resources[projection.resource]
            let current = cloudStateObservations[machine]?.freshness == .current
            let directory: String?
            if machine.deviceInstance != nil {
                directory = resource?.kind == .terminal ? resource?.detail : nil
            } else if let resource, resource.kind == .terminal {
                directory = current
                    ? cloudStates[machine]?.lookupIndex.terminal(id: projection.resource.key)?.cwd
                    : acceptedStaleCloudDirectory(for: resource)
            } else {
                directory = nil
            }
            if let directory, workspace.reportedPanelDirectory(panelId: projection.panelID) == directory { continue }
            workspace.updateCloudPanelDirectory(panelId: projection.panelID, directory: directory)
        }
    }
}
