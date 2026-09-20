import Foundation

extension SurfaceCatalog {
    /// Device records, not terminal escape sequences or old local overrides, own mirror names.
    func reconcileDeviceNames(on machine: SurfaceMachineID) {
        guard machine.deviceInstance != nil else { return }
        let environment = cloudWorkspaceRenameService.environment
        let localIDs = Set(projections.filter { $0.resource.machine == machine }.map(\.workspaceID))
        for localID in localIDs {
            guard let workspace = environment.workspace(localID) else { continue }
            // Older builds accidentally stored device IDs in the Cloud-only binding
            // when a user renamed from the left sidebar. Projections own device identity.
            if let binding = workspace.cloudVMBinding,
               SurfaceMachineID(rawValue: binding.vmID).deviceInstance != nil {
                workspace.cloudVMBinding = nil
            }
            let members = projections.filter { $0.workspaceID == localID }
            for projection in members where projection.resource.machine == machine {
                guard let resource = resources[projection.resource], resource.kind == .terminal,
                      workspace.panels[projection.panelID] != nil else { continue }
                let tabID = projection.remoteTabID ?? resource.id.key
                let title = resource.remoteViews?.first { $0.tabID == tabID }?.name ?? resource.title
                if let pending = pendingCloudRenameName(for: .tab(machine: machine, id: tabID)),
                   !pending.isEmpty, pending != title { continue }
                if workspace.panelCustomTitles[projection.panelID] != title {
                    workspace.setPanelCustomTitle(panelId: projection.panelID, title: title, source: .remote,
                        propagateToRemoteTmux: false, propagateToCloud: false)
                }
            }
            guard Set(members.map(\.panelID)) == Set(workspace.panels.keys),
                  let target = cloudWorkspaceRenameService.inferredRemoteWorkspaceTarget(
                    projections: Array(members), resources: [], resourcesByID: resources), target.machine == machine,
                  let remote = members.compactMap({ resources[$0.resource] }).flatMap(\.remoteWorkspaces)
                    .first(where: { $0.id == target.remoteWorkspaceID }) else { continue }
            if let pending = pendingCloudRenameName(for: .workspace(machine: machine, id: remote.id)),
               pending != remote.name { continue }
            guard workspace.customTitle != remote.name else { continue }
            let manager = workspace.owningTabManager ?? environment.tabManager(localID)
            manager?.setCustomTitle(tabId: localID, title: remote.name, source: .remote,
                propagateToRemoteTmux: false, propagateToCloud: false)
        }
    }
}
