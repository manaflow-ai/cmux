import Foundation

extension CloudWorkspaceRenameService {
    func bindingReconciliation(
        binding: WorkspaceCloudVMBinding,
        machine: SurfaceMachineID,
        state: CloudVMState,
        observation: CloudVMStateObservation,
        projections: [SurfaceProjection],
        resources: [SurfaceResource],
        resourcesByID: [SurfaceResourceID: SurfaceResource]? = nil
    ) -> BindingReconciliation {
        guard let remoteID = binding.remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteID.isEmpty else { return .keep }
        guard observation.freshness == .current,
              state.cursor != nil,
              state.document.containsCollection("workspaces") else { return .keep }
        guard !state.workspaceIDs.contains(remoteID) else { return .keep }
        guard let target = inferredRemoteWorkspaceTarget(
            projections: projections,
            resources: resources,
            resourcesByID: resourcesByID
        ), target.machine == machine,
        state.workspaceIDs.contains(target.remoteWorkspaceID) else { return .clear }
        return .rebind(machine: target.machine, remoteWorkspaceID: target.remoteWorkspaceID)
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
            let resourcesByID = Dictionary(resources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let projectionsByWorkspace = Dictionary(
                grouping: snapshot.projections.filter { $0.resource.machine == machine },
                by: \.workspaceID
            )
            for workspace in environment.workspaces() {
                guard let binding = workspace.cloudVMBinding, binding.vmID == machine.cloudMachineID,
                      let id = binding.remoteWorkspaceID else { continue }
                switch bindingReconciliation(
                    binding: binding,
                    machine: machine,
                    state: state,
                    observation: observation,
                    projections: projectionsByWorkspace[workspace.id] ?? [],
                    resources: resources,
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
                guard let currentBinding = workspace.cloudVMBinding,
                      let id = currentBinding.remoteWorkspaceID,
                      let remote = state.lookupIndex.workspace(id: id) else { continue }
                if workspace.customTitle == remote.name, workspace.effectiveCustomTitleSource == .user { continue }
                // Submission returns before local title setters run. Pending names
                // are request metadata, not accepted UI values; both projections
                // keep rendering this graph until the daemon acknowledges a write.
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
            if workspace.panelCustomTitles[projection.panelID] == tab.name,
               workspace.panelCustomTitleSources[projection.panelID] == .user { continue }
            guard workspace.panelCustomTitles[projection.panelID] != tab.name
                    || (tab.name != nil && workspace.panelCustomTitleSources[projection.panelID] != .remote) else { continue }
            _ = workspace.setPanelCustomTitle(panelId: projection.panelID, title: tab.name, source: .remote,
                                               propagateToRemoteTmux: false, propagateToCloud: false)
        }
    }
}
