import Foundation

extension CloudWorkspaceRenameService {
    func bindingReconciliation(
        binding: WorkspaceCloudVMBinding,
        machine: SurfaceMachineID,
        state: CloudVMState,
        observation: CloudVMStateObservation,
        projections: [SurfaceProjection],
        resourcesByID: [SurfaceResourceID: SurfaceResource]
    ) -> BindingReconciliation {
        guard let remoteID = binding.remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteID.isEmpty else { return .keep }
        guard observation.freshness == .current,
              state.cursor != nil,
              state.document.containsCollection("workspaces") else { return .keep }
        guard !state.workspaceIDs.contains(remoteID) else { return .keep }
        guard let target = inferredRemoteWorkspaceTarget(
            projections: projections,
            resourcesByID: resourcesByID
        ), target.machine == machine,
        state.workspaceIDs.contains(target.remoteWorkspaceID) else { return .clear }
        return .rebind(machine: target.machine, remoteWorkspaceID: target.remoteWorkspaceID)
    }

    /// Applies one accepted workspace name without scanning other bindings.
    @MainActor
    func reconcileRemoteWorkspaceName(
        workspace: Workspace,
        machine: SurfaceMachineID,
        state: CloudVMState,
        catalog: SurfaceCatalog,
        observation: CloudVMStateObservation
    ) {
        guard catalog.cloudStates[machine] == state,
              observation.freshness == .current,
              let binding = workspace.cloudVMBinding,
              binding.vmID == machine.cloudMachineID,
              let id = binding.remoteWorkspaceID,
              let remote = state.lookupIndex.workspace(id: id) else { return }
        let key = CloudRenameCoordinator.Key.workspace(machine: machine, id: id)
        if let pending = catalog.pendingCloudRenameName(for: key), pending != remote.name { return }
        // Equal confirmations preserve user provenance across refresh.
        // A user title without a pending write is also authoritative: it may
        // have been entered while creation/discovery was in flight.
        if workspace.effectiveCustomTitleSource == .user { return }
        guard workspace.customTitle != remote.name || workspace.effectiveCustomTitleSource != .remote else { return }
        let manager = workspace.owningTabManager ?? environment.tabManager(workspace.id)
        _ = manager?.setCustomTitle(tabId: workspace.id, title: remote.name, source: .remote,
                                    propagateToRemoteTmux: false, propagateToCloud: false)
    }

    /// Reconciles only the identities touched by an accepted event. Full snapshots
    /// also repair workspace names; process-title events never rewrite other rows.
    @MainActor
    func reconcileRemoteState(
        machine: SurfaceMachineID,
        state: CloudVMState,
        catalog: SurfaceCatalog,
        observation: CloudVMStateObservation,
        affectedResources: Set<SurfaceResourceID>? = nil,
        workspaceNamesChanged: Bool = true
    ) {
        guard case .cloud = machine, catalog.cloudStates[machine] == state else { return }
        if workspaceNamesChanged {
            let snapshot = catalog.snapshot
            let resourcesByID = catalog.resources
            let projectionsByWorkspace = Dictionary(
                grouping: snapshot.projections.filter { $0.resource.machine == machine },
                by: \.workspaceID
            )
            for workspace in environment.workspaces() {
                guard let binding = workspace.cloudVMBinding, binding.vmID == machine.cloudMachineID,
                      binding.remoteWorkspaceID != nil else { continue }
                switch bindingReconciliation(
                    binding: binding,
                    machine: machine,
                    state: state,
                    observation: observation,
                    projections: projectionsByWorkspace[workspace.id] ?? [],
                    resourcesByID: resourcesByID
                ) {
                case .keep:
                    break
                case .clear:
                    workspace.cloudVMBinding = nil
                    continue
                case .rebind(let targetMachine, let targetWorkspaceID):
                    workspace.cloudVMBinding = WorkspaceCloudVMBinding(
                        vmID: targetMachine.cloudMachineID ?? binding.vmID,
                        isBase: binding.isBase,
                        remoteWorkspaceID: targetWorkspaceID
                    )
                }
                reconcileRemoteWorkspaceName(workspace: workspace, machine: machine, state: state,
                                             catalog: catalog, observation: observation)
            }
        }
        for projection in catalog.projections where projection.resource.machine == machine {
            if let affectedResources, !affectedResources.contains(projection.resource) { continue }
            guard let resource = catalog.resources[projection.resource],
                  let workspace = environment.workspace(projection.workspaceID),
                  workspace.panels[projection.panelID] != nil else { continue }
            guard resource.kind == .terminal else { continue }
            if workspace.panelTitles[projection.panelID] != resource.cloudProcessDisplayTitle {
                _ = workspace.updatePanelTitle(panelId: projection.panelID, title: resource.cloudProcessDisplayTitle)
            }
            guard let tabID = remoteTabID(for: projection, resource: resource),
                  let tab = state.lookupIndex.tab(id: tabID) else { continue }
            let key = CloudRenameCoordinator.Key.tab(machine: machine, id: tabID)
            if let pending = catalog.pendingCloudRenameName(for: key), pending != (tab.name ?? "") { continue }
            guard workspace.panelCustomTitles[projection.panelID] != tab.name else { continue }
            if workspace.panelCustomTitles[projection.panelID] == tab.name,
               workspace.panelCustomTitleSources[projection.panelID] == .user { continue }
            guard workspace.panelCustomTitles[projection.panelID] != tab.name
                    || (tab.name != nil && workspace.panelCustomTitleSources[projection.panelID] != .remote) else { continue }
            _ = workspace.setPanelCustomTitle(panelId: projection.panelID, title: tab.name, source: .remote,
                                               propagateToRemoteTmux: false, propagateToCloud: false)
        }
    }
}
