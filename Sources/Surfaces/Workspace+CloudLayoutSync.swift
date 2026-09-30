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

    /// The native split tree in daemon tab IDs, or nil while any pane holds a view
    /// without a daemon tab (a creation in flight, or a local preview).
    func cloudLayoutSyncTree(machine: SurfaceMachineID, catalog: SurfaceCatalog) -> CloudLayoutSyncTree? {
        var remoteTabs: [String: String] = [:]
        for panelID in panels.keys {
            guard let tab = surfaceIdFromPanelId(panelID),
                  let projection = catalog.projection(forPanel: panelID),
                  projection.workspaceID == id, projection.resource.machine == machine,
                  let remoteTabID = projection.remoteTabID else { return nil }
            remoteTabs[tab.uuid.uuidString] = remoteTabID
        }
        return Self.cloudLayoutSyncTree(bonsplitController.treeSnapshot(), remoteTabs: remoteTabs)
    }

    private static func cloudLayoutSyncTree(_ node: ExternalTreeNode, remoteTabs: [String: String]) -> CloudLayoutSyncTree? {
        switch node {
        case .pane(let pane):
            let tabIDs = pane.tabs.compactMap { remoteTabs[$0.id] }
            guard !tabIDs.isEmpty, tabIDs.count == pane.tabs.count else { return nil }
            return .leaf(tabIDs: tabIDs, activeTabID: pane.selectedTabId.flatMap { remoteTabs[$0] })
        case .split(let split):
            guard let first = cloudLayoutSyncTree(split.first, remoteTabs: remoteTabs),
                  let second = cloudLayoutSyncTree(split.second, remoteTabs: remoteTabs) else { return nil }
            return .split(horizontal: split.orientation == "horizontal", ratio: split.dividerPosition, first: first, second: second)
        }
    }
}
