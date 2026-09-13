import Foundation

extension CloudWorkspaceRenameService {
    /// Reconciles only the identities touched by an accepted event. Full snapshots
    /// also repair workspace names; process-title events never rewrite other rows.
    @MainActor
    func reconcileRemoteState(
        machine: SurfaceMachineID,
        state: CloudVMState,
        catalog: SurfaceCatalog,
        affectedResources: Set<SurfaceResourceID>? = nil,
        workspaceNamesChanged: Bool = true
    ) {
        guard case .cloud = machine, catalog.cloudStates[machine] == state else { return }
        if workspaceNamesChanged {
            for workspace in environment.workspaces() {
                guard let binding = workspace.cloudVMBinding, binding.vmID == machine.cloudMachineID,
                      let id = binding.remoteWorkspaceID, let remote = state.lookupIndex.workspace(id: id) else { continue }
                let key = CloudRenameCoordinator.Key.workspace(machine: machine, id: id)
                if let pending = catalog.cloudRenameCoordinator.pendingName(for: key), pending != remote.name { continue }
                // Pending user edits are protected above. Confirmed names belong
                // to the daemon; a generated prefix must not become a local alias.
                guard workspace.customTitle != remote.name || workspace.effectiveCustomTitleSource != .remote else { continue }
                let manager = workspace.owningTabManager ?? environment.tabManager(workspace.id)
                _ = manager?.setCustomTitle(tabId: workspace.id, title: remote.name, source: .remote,
                                           propagateToRemoteTmux: false, propagateToCloud: false)
            }
        }
        for projection in catalog.projections where projection.resource.machine == machine {
            if let affectedResources, !affectedResources.contains(projection.resource) { continue }
            guard let resource = catalog.resources[projection.resource], resource.kind == .terminal,
                  let workspace = environment.workspace(projection.workspaceID),
                  workspace.panels[projection.panelID] != nil else { continue }
            if workspace.panelTitles[projection.panelID] != resource.cloudProcessDisplayTitle {
                _ = workspace.updatePanelTitle(panelId: projection.panelID, title: resource.cloudProcessDisplayTitle)
            }
            guard let tabID = remoteTabID(for: projection, resource: resource),
                  let tab = state.lookupIndex.tab(id: tabID) else { continue }
            let key = CloudRenameCoordinator.Key.tab(machine: machine, id: tabID)
            if let pending = catalog.cloudRenameCoordinator.pendingName(for: key), pending != (tab.name ?? "") { continue }
            guard workspace.panelCustomTitles[projection.panelID] != tab.name
                    || (tab.name != nil && workspace.panelCustomTitleSources[projection.panelID] != .remote) else { continue }
            _ = workspace.setPanelCustomTitle(panelId: projection.panelID, title: tab.name, source: .remote,
                                               propagateToRemoteTmux: false, propagateToCloud: false)
        }
    }
}
