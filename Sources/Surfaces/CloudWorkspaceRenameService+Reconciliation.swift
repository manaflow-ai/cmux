import Foundation

extension CloudWorkspaceRenameService {
    enum BindingReconciliation: Equatable {
        case keep
        case clear
        case rebind(machine: SurfaceMachineID, remoteWorkspaceID: String)
    }

    /// Decides whether one persisted binding is still valid against a complete,
    /// current daemon graph. Missing or partial transport state never clears a
    /// binding: only a cursor-bearing graph with an explicit workspace collection
    /// can prove that the remote workspace was deleted. If live projections agree
    /// on one surviving workspace, the local owner follows that exact identity;
    /// mixed projections remain unbound rather than moving a terminal implicitly.
    func bindingReconciliation(
        binding: WorkspaceCloudVMBinding?,
        machine: SurfaceMachineID,
        state: CloudVMState,
        observation: CloudVMStateObservation,
        projections: [SurfaceProjection],
        resources: [SurfaceResource],
        resourcesByID: [SurfaceResourceID: SurfaceResource]? = nil
    ) -> BindingReconciliation {
        guard let binding,
              binding.vmID == machine.cloudMachineID,
              let remoteID = binding.remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteID.isEmpty else { return .keep }
        guard observation.freshness == .current,
              state.cursor != nil,
              state.document.containsCollection("workspaces") else { return .keep }
        guard !state.workspaceIDs.contains(remoteID) else { return .keep }
        guard let target = inferredRemoteWorkspaceTarget(
            projections: projections,
            resources: resources,
            resourcesByID: resourcesByID
        ),
              target.machine == machine,
              state.workspaceIDs.contains(target.remoteWorkspaceID) else { return .clear }
        return .rebind(machine: target.machine, remoteWorkspaceID: target.remoteWorkspaceID)
    }

    /// Applies daemon-owned names to every local projection that carries an
    /// exact remote identity. A remote observation uses `.remote` and disables
    /// both local transport propagations.
    ///
    /// While a local intent is in flight, a different remote value stays visible
    /// until the command succeeds or rolls back. This avoids a polling race
    /// without creating a second durable source of truth.
    @MainActor
    func reconcileRemoteState(
        machine: SurfaceMachineID,
        state: CloudVMState,
        catalog: SurfaceCatalog,
        observation: CloudVMStateObservation
    ) {
        guard case .cloud = machine else { return }
        let snapshot = catalog.snapshot
        // Synchronizable snapshots reject duplicate identity rows at the parser
        // boundary. Keep these defensive maps total for legacy callers that may
        // construct a value directly; missing relationships still fail closed
        // below instead of selecting a placement by array order.
        let workspacesByID = state.workspaces.reduce(into: [String: CloudVMWorkspaceState]()) {
            $0[$1.id] = $1
        }
        let tabsByID = state.tabs.reduce(into: [String: CloudVMTabState]()) {
            $0[$1.id] = $1
        }
        let resourcesByID = snapshot.resources(on: machine).reduce(into: [SurfaceResourceID: SurfaceResource]()) {
            $0[$1.id] = $1
        }
        let projectionsByWorkspace = Dictionary(
            grouping: snapshot.projections.filter { $0.resource.machine == machine },
            by: \.workspaceID
        )
        let localWorkspaces = environment.workspaces()
        let localWorkspacesByID = Dictionary(
            localWorkspaces.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for workspace in localWorkspaces {
            guard let binding = workspace.cloudVMBinding,
                  binding.vmID == machine.cloudMachineID,
                  var remoteID = binding.remoteWorkspaceID,
                  !remoteID.isEmpty else { continue }
            let projections = projectionsByWorkspace[workspace.id] ?? []
            switch bindingReconciliation(
                binding: binding,
                machine: machine,
                state: state,
                observation: observation,
                projections: projections,
                resources: snapshot.resources,
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
                remoteID = targetWorkspaceID
            }
            guard let remote = workspacesByID[remoteID] else { continue }

            let intentKey = CloudRenameCoordinator.Key.workspace(machine: machine, id: remoteID)
            if let pending = catalog.cloudRenameCoordinator.pendingName(for: intentKey), pending != remote.name {
                continue
            }
            let displayName = workspaceDisplayName(
                machine: machine,
                remoteName: remote.name,
                currentTitleSource: workspace.effectiveCustomTitleSource,
                currentCustomTitle: workspace.customTitle
            )
            let manager = workspace.owningTabManager ?? environment.tabManager(workspace.id)
            _ = manager?.setCustomTitle(
                tabId: workspace.id,
                title: displayName,
                source: .remote,
                propagateToRemoteTmux: false,
                propagateToCloud: false
            )
        }

        for projection in snapshot.projections where projection.resource.machine == machine {
            guard let workspace = localWorkspacesByID[projection.workspaceID],
                  workspace.panels[projection.panelID] != nil,
                  let resource = resourcesByID[projection.resource],
                  resource.kind == .terminal
            else { continue }

            let tabID = remoteTabID(for: projection, resource: resource)
            guard let tabID, let tab = tabsByID[tabID] else { continue }
            let intentKey = CloudRenameCoordinator.Key.tab(machine: machine, id: tabID)
            if let pending = catalog.cloudRenameCoordinator.pendingName(for: intentKey), pending != (tab.name ?? "") {
                continue
            }
            _ = workspace.setPanelCustomTitle(
                panelId: projection.panelID,
                title: tab.name,
                source: .remote,
                propagateToRemoteTmux: false,
                propagateToCloud: false
            )
        }
    }

    private func workspaceDisplayName(
        machine: SurfaceMachineID,
        remoteName: String,
        currentTitleSource: Workspace.CustomTitleSource?,
        currentCustomTitle: String?
    ) -> String {
        // Preserve the machine prefix only for a title this feature created.
        // A user-entered title remains exact after the daemon echoes it.
        let prefix = "\(machine.rawValue): "
        if currentTitleSource == .remote,
           currentCustomTitle?.hasPrefix(prefix) == true {
            return prefix + remoteName
        }
        return remoteName
    }

}
