import CmuxCloud
import CmuxSurfaceCatalogModel
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

    /// Returns false while a workspace tab is present in the accepted daemon
    /// graph but its catalog resource has not arrived yet. Retiring a local
    /// projection from that partial graph would turn an inventory race into a
    /// user-visible pane close.
    func cloudWorkspaceGraphIsComplete(
        machine: SurfaceMachineID,
        state: CloudVMState,
        workspaceID: String
    ) -> Bool {
        isCloudGraphComplete(machine: machine, state: state, workspaceID: workspaceID)
    }

    /// Returns false while any recognized tab in the accepted graph lacks its
    /// catalog resource. Provider attachment cleanup uses this stronger
    /// machine-wide fence so an incomplete inventory cannot close a live pane.
    func cloudGraphIsComplete(machine: SurfaceMachineID, state: CloudVMState) -> Bool {
        isCloudGraphComplete(machine: machine, state: state, workspaceID: nil)
    }

    private func isCloudGraphComplete(
        machine: SurfaceMachineID,
        state: CloudVMState,
        workspaceID: String?
    ) -> Bool {
        let resources = Set(snapshot.resources(on: machine).map(\.id))
        for tab in state.tabs {
            guard let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID),
                  workspaceID == nil || screen.workspaceID == workspaceID else { continue }
            let kind: SurfaceResourceKind
            switch tab.contentKind {
            case "terminal": kind = .terminal
            case "browser": kind = .browser
            case "display", "screen": kind = .display
            default: return false
            }
            guard resources.contains(SurfaceResourceID(machine: machine, kind: kind, key: tab.contentID)) else {
                return false
            }
        }
        return true
    }

    /// Workspace-row actions may outlive the immutable row that launched them.
    /// Resolve its identity again at the last synchronous point before opening,
    /// so a rename, move or close during refresh cannot resurrect captured members.
    /// Arbitrary groups and local workspaces retain their supplied membership.
    func currentCloudWorkspace(_ group: SurfaceResourceGroup) throws -> (group: SurfaceResourceGroup, layout: SurfaceProjectionLayout?)? {
        if let workspaceID = group.remoteWorkspaceID, let machine = group.placements.first?.resource.machine {
            try checkCloudWorkspaceNavigation(machine: machine, workspaceID: workspaceID)
        }
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
        Dictionary(uniqueKeysWithValues: Set(resources.map(\.machine)).filter { !$0.isLocal }.map { machine in
            let token = cloudWorkspaceProjectionCoordinator.beginLocalMutation(on: machine)
            (provider(for: machine) as? any SurfaceProjectionMutationObserving)?.beginProjectionMutation(token)
            return (machine, token)
        })
    }

    func endProjectionMutation(_ tokens: [SurfaceMachineID: UUID]) {
        for (machine, token) in tokens {
            cloudWorkspaceProjectionCoordinator.endLocalMutation(token, on: machine, catalog: self)
            (provider(for: machine) as? any SurfaceProjectionMutationObserving)?.endProjectionMutation(token)
        }
    }

    func requestCloudWorkspaceProjection(_ workspaceID: UUID) {
        guard let binding = cloudWorkspaceProjectionCoordinator.environment.bindings()[workspaceID] else { return }
        cloudWorkspaceProjectionCoordinator.request(machine: SurfaceMachineID(rawValue: binding.vmID), catalog: self)
    }

}
