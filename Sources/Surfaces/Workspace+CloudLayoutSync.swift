import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

@MainActor
extension Workspace {
    /// Writes a native arrangement change of a bound Cloud workspace to its machine.
    ///
    /// Called from every Bonsplit layout callback. Changes this workspace makes while
    /// applying the machine's own layout are programmatic and are not echoed back.
    func cloudLayoutDidChange() {
        guard !isProgrammaticSplit, !isRemoteTmuxMirror,
              let binding = cloudVMBinding, let remoteWorkspaceID = binding.remoteWorkspaceID else { return }
        let machine = SurfaceMachineID(rawValue: binding.vmID)
        let catalog = SurfaceCatalog.shared
        guard !machine.isLocal, !machine.isDevice, catalog.cloudStates[machine] != nil,
              catalog.provider(for: machine) is any SurfaceWorkspaceLayoutSyncing else { return }
        catalog.cloudWorkspaceLayoutSyncCoordinator.layoutDidChange(
            workspaceID: id, machine: machine, remoteWorkspaceID: remoteWorkspaceID, catalog: catalog
        ) { [weak self] in
            self?.cloudLayoutSyncTree(machine: machine, catalog: catalog)
        }
    }

    /// The native split tree of this workspace's daemon tabs. Local views (a Cloud
    /// Desktop, a port preview, a pane still being created) are not the machine's to
    /// arrange, so they are left out and a pane holding only them collapses.
    func cloudLayoutSyncTree(machine: SurfaceMachineID, catalog: SurfaceCatalog) -> CloudLayoutSyncTree? {
        cloudLayoutSyncTree(projections: panels.keys.compactMap { catalog.projection(forPanel: $0) }, machine: machine)
    }

    /// The same tree from explicit projections, for callers that already hold them.
    func cloudLayoutSyncTree(projections: [SurfaceProjection], machine: SurfaceMachineID) -> CloudLayoutSyncTree? {
        var remoteTabs: [String: String] = [:]
        for projection in projections where projection.workspaceID == id && projection.resource.machine == machine {
            guard panels[projection.panelID] != nil, let tab = surfaceIdFromPanelId(projection.panelID),
                  let remoteTabID = projection.remoteTabID else { continue }
            remoteTabs[tab.uuid.uuidString] = remoteTabID
        }
        return Self.cloudLayoutSyncTree(bonsplitController.treeSnapshot(), remoteTabs: remoteTabs)
    }

    private static func cloudLayoutSyncTree(_ node: ExternalTreeNode, remoteTabs: [String: String]) -> CloudLayoutSyncTree? {
        switch node {
        case .pane(let pane):
            let tabIDs = pane.tabs.compactMap { remoteTabs[$0.id] }
            guard !tabIDs.isEmpty else { return nil }
            return .leaf(tabIDs: tabIDs, activeTabID: pane.selectedTabId.flatMap { remoteTabs[$0] })
        case .split(let split):
            switch (cloudLayoutSyncTree(split.first, remoteTabs: remoteTabs),
                    cloudLayoutSyncTree(split.second, remoteTabs: remoteTabs)) {
            case let (first?, second?):
                return .split(horizontal: split.orientation == "horizontal", ratio: split.dividerPosition, first: first, second: second)
            case let (only?, nil), let (nil, only?):
                return only
            case (nil, nil):
                return nil
            }
        }
    }
}
