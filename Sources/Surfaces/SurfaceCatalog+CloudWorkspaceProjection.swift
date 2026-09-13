import Foundation

extension SurfaceCatalog {
    func reconcileCloudRemoteState(machine: SurfaceMachineID, state: CloudVMState, observation: CloudVMStateObservation? = nil) {
        guard cloudStates[machine] == state else { return }
        cloudPlacementCoordinator.reconcileRemoteState(state, catalog: self)
        cloudWorkspaceProjectionCoordinator.request(machine: machine, catalog: self)
        cloudWorkspaceRenameService.reconcileRemoteState(
            machine: machine,
            state: state,
            catalog: self,
            observation: observation ?? cloudStateObservations[machine] ?? .current
        )
    }


    /// Geometry is a projection of the installed graph, just like its catalog rows.
    /// A refresh or event must pass the provider's ordering fence before either
    /// consumer sees it. No network read is permitted at this projection boundary.
    func cloudWorkspaceLayout(machine: SurfaceMachineID, workspaceID: String) -> SurfaceProjectionLayout? {
        guard let state = cloudStates[machine], let document = state.snapshotObject() else { return nil }
        return CloudWorkspaceLayoutTranslator.projectionLayout(
            snapshot: document, machine: machine, workspaceID: workspaceID,
            resources: snapshot.resources(on: machine)
        )
    }

    /// Workspace-row actions may outlive the immutable row that launched them.
    /// Resolve its identity again at the last synchronous point before opening,
    /// so a rename, move or close during refresh cannot resurrect captured members.
    /// Arbitrary groups and local workspaces retain their supplied membership.
    func currentCloudWorkspace(_ group: SurfaceResourceGroup) throws -> (group: SurfaceResourceGroup, layout: SurfaceProjectionLayout?)? {
        guard group.representsWorkspace, let workspaceID = group.remoteWorkspaceID,
              let machine = group.placements.first?.resource.machine,
              !machine.isLocal, cloudStates[machine] != nil,
              group.placements.allSatisfy({ $0.resource.machine == machine }) else { return nil }
        return (
            try remoteWorkspaceGroup(machine: machine, workspaceID: workspaceID),
            cloudWorkspaceLayout(machine: machine, workspaceID: workspaceID)
        )
    }

    /// A newly opened/restored pane immediately receives the already accepted
    /// names. Waiting for the next event leaves quiet terminals stale indefinitely.
    func reconcileCloudProjection(_ projection: SurfaceProjection) {
        guard let state = cloudStates[projection.resource.machine],
              cloudStateObservations[state.machine]?.freshness == .current else { return }
        cloudWorkspaceRenameService.reconcileRemoteState(machine: state.machine, state: state, catalog: self, observation: cloudStateObservations[state.machine] ?? .current)
    }
    func beginProjectionMutation(for resources: [SurfaceResourceID]) -> [SurfaceMachineID: UUID] {
        Dictionary(uniqueKeysWithValues: Set(resources.map(\.machine)).filter { !$0.isLocal }.map {
            ($0, cloudWorkspaceProjectionCoordinator.beginLocalMutation(on: $0))
        })
    }

    func endProjectionMutation(_ tokens: [SurfaceMachineID: UUID]) {
        for (machine, token) in tokens { cloudWorkspaceProjectionCoordinator.endLocalMutation(token, on: machine, catalog: self) }
    }

    func requestCloudWorkspaceProjection(_ workspaceID: UUID) {
        guard let binding = cloudWorkspaceProjectionCoordinator.environment.bindings()[workspaceID] else { return }
        cloudWorkspaceProjectionCoordinator.request(machine: .cloud(binding.vmID), catalog: self)
    }

}
