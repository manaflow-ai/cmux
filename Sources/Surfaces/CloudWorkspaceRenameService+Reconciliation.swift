import Foundation

extension CloudWorkspaceRenameService {
    func bindingReconciliation(
        binding: WorkspaceCloudVMBinding,
        machine: SurfaceMachineID,
        state: CloudVMState,
        observation: CloudVMStateObservation,
        projections: [SurfaceProjection],
        resources: [SurfaceResource]
    ) -> BindingReconciliation {
        guard let remoteID = binding.remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteID.isEmpty else { return .keep }
        guard observation.freshness == .current,
              state.cursor != nil,
              state.document.containsCollection("workspaces") else { return .keep }
        guard !state.workspaceIDs.contains(remoteID) else { return .keep }
        guard let target = inferredRemoteWorkspaceTarget(
            projections: projections,
            resources: resources
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
        // A pending intent is the name the person already chose: the local title
        // shows it now, and a failed intent falls back to the accepted graph on
        // the next pass. A process-title or notification event in that gap can
        // never turn the old daemon name into a new local rename.
        let name = catalog.pendingCloudRenameName(for: key) ?? remote.name
        // Equal confirmations preserve user provenance across refresh.
        // A user title without a pending write is also authoritative: it may
        // have been entered while creation/discovery was in flight.
        if workspace.effectiveCustomTitleSource == .user { return }
        guard workspace.customTitle != name || workspace.effectiveCustomTitleSource != .remote else { return }
        let manager = workspace.owningTabManager ?? environment.tabManager(workspace.id)
        _ = manager?.setCustomTitle(tabId: workspace.id, title: name, source: .remote,
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
            let resources = snapshot.resources(on: machine)
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
                    resources: resources
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
            if resource.kind == .terminal {
                workspace.updateCloudPanelDirectory(panelId: projection.panelID, directory: resource.detail)
            } else {
                workspace.clearRemotePanelDirectory(panelId: projection.panelID)
                continue
            }
            if workspace.panelTitles[projection.panelID] != resource.cloudProcessDisplayTitle {
                _ = workspace.updatePanelTitle(panelId: projection.panelID, title: resource.cloudProcessDisplayTitle)
            }
            guard let tabID = remoteTabID(for: projection, resource: resource),
                  let tab = state.lookupIndex.tab(id: tabID) else { continue }
            // The same rule for placements: an exact tab intent, then a
            // terminal-wide one, then the accepted tab name. An empty pending
            // name is a clear, which the daemon reports as no name.
            let pending = catalog.pendingCloudRenameName(for: .tab(machine: machine, id: tabID))
                ?? catalog.pendingCloudRenameName(for: .terminal(machine: machine, id: resource.id.key))
            let name: String?
            if let pending { name = pending.isEmpty ? nil : pending } else { name = tab.name }
            guard workspace.panelCustomTitles[projection.panelID] != name else { continue }
            if workspace.panelCustomTitles[projection.panelID] == name,
               workspace.panelCustomTitleSources[projection.panelID] == .user { continue }
            guard workspace.panelCustomTitles[projection.panelID] != name
                    || (name != nil && workspace.panelCustomTitleSources[projection.panelID] != .remote) else { continue }
            _ = workspace.setPanelCustomTitle(panelId: projection.panelID, title: name, source: .remote,
                                               propagateToRemoteTmux: false, propagateToCloud: false)
        }
    }
}
