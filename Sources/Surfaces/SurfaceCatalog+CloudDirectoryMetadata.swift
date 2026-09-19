import Foundation

extension SurfaceCatalog {
    /// Retain stale graphs for diagnostics without presenting their cwd as current in the tree or CLI.
    func resourceForPresentation(_ resource: SurfaceResource) -> SurfaceResource {
        guard resource.kind == .terminal,
              cloudStateObservations[resource.machine]?.freshness == .stale else { return resource }
        var result = resource
        result.detail = nil
        return result
    }

    /// Projects accepted directory and machine metadata independently from name reconciliation.
    /// The catalog remains authoritative; Workspace owns only the UI-facing projection.
    func updateCloudDirectoryMetadata(on machine: SurfaceMachineID) {
        let projectedWorkspaceIDs = Set(projections.filter { $0.resource.machine == machine }.map(\.workspaceID))
        for workspace in cloudWorkspaceRenameService.environment.workspaces()
            where workspace.cloudVMBinding?.vmID == machine.cloudMachineID || projectedWorkspaceIDs.contains(workspace.id)
                || workspace.cloudBindingState.projectedResources.values.contains(where: { $0.machine == machine }) {
            updateCloudDirectoryMetadata(in: workspace)
        }
    }

    func updateCloudDirectoryMetadata(localWorkspaceID: UUID) {
        guard let workspace = cloudWorkspaceRenameService.environment.workspace(localWorkspaceID) else { return }
        updateCloudDirectoryMetadata(in: workspace)
    }

    private func updateCloudDirectoryMetadata(in workspace: Workspace) {
        // Saved projections establish ownership even before their provider rediscovers the resource.
        let projected = projectionRecords(forWorkspace: workspace.id).filter { !$0.resource.machine.isLocal }
        let resourcesByPanel = Dictionary(projected.map { ($0.panelID, $0.resource) }, uniquingKeysWith: { first, _ in first })
        var machineIDs = Set(projected.compactMap { $0.resource.machine.cloudMachineID })
        if let binding = workspace.cloudVMBinding { machineIDs.insert(binding.vmID) }
        let names = Dictionary(uniqueKeysWithValues: machineIDs.map { id in
            (id, machines[.cloud(id)]?.name ?? id)
        })
        let previous = workspace.cloudBindingState.projectedResources
        workspace.cloudBindingState.updateCatalogMetadata(resources: resourcesByPanel, machineNames: names)
        for panelID in previous.keys where resourcesByPanel[panelID] == nil && workspace.panels[panelID] != nil {
            workspace.clearRemotePanelDirectory(panelId: panelID)
        }
        for projection in projected where workspace.panels[projection.panelID] != nil {
            let machine = projection.resource.machine
            let resource = resources[projection.resource]
            let current = cloudStateObservations[machine]?.freshness == .current
            let directory = current && resource?.kind == .terminal
                ? cloudStates[machine]?.lookupIndex.terminal(id: projection.resource.key)?.cwd : nil
            workspace.updateCloudPanelDirectory(panelId: projection.panelID, directory: directory)
        }
    }
}
