import Bonsplit
import CmuxPanes
import CmuxWorkspaces
import Foundation

/// `Workspace` is the tree-reading host for its `WorkspaceSurfaceListModel`.
/// Every member erases the opaque bonsplit `TabID`/`PaneID` types to `UUID` at
/// the boundary and reads the live `BonsplitController` split tree and the
/// `PaneTreeModel` panel registry, reproducing the legacy computed-property
/// reads exactly. The model is held by `Workspace` and references this host
/// weakly, so there is no retain cycle.
extension Workspace: WorkspaceSurfaceTreeReading {
    func panelIdFromSurfaceId(_ surfaceId: TabID) -> UUID? {
        paneTree.panelId(forSurfaceId: surfaceId)
    }

    func surfaceIdFromPanelId(_ panelId: UUID) -> TabID? {
        paneTree.surfaceId(forPanelId: panelId)
    }

    /// The pane that currently holds this panel's surface.
    ///
    /// Bonsplit keeps a pane-ownership index, so ask it. The scan this replaced
    /// built a `Tab` for every tab in every pane, and `Tab.init(from:)` copies
    /// all fourteen `TabItem` properties. Run inside a SwiftUI update, as the
    /// portal-ownership resolver does, that subscribed the update to every tab
    /// title in the window, so an animating title invalidated the terminal
    /// surfaces. `DockSplitStore.paneId(forPanelId:)` already did it this way.
    func paneId(forPanelId panelId: UUID) -> PaneID? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        return bonsplitController.paneId(containing: tabId)
    }

    func indexInPane(forPanelId panelId: UUID) -> Int? {
        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return nil }
        return bonsplitController.tabs(inPane: paneId).firstIndex(where: { $0.id == tabId })
    }

    var surfaceIdsInTabOrderAcrossAllPanes: [UUID] {
        bonsplitController.allTabIds.map(\.uuid)
    }

    var focusedPaneSelectedSurfaceId: UUID? {
        guard let paneId = bonsplitController.focusedPaneId,
              let tab = bonsplitController.selectedTab(inPane: paneId) else {
            return nil
        }
        return tab.id.uuid
    }

    var allPaneIds: [UUID] {
        bonsplitController.allPaneIds.map(\.id)
    }

    var spatiallyOrderedPaneIds: [UUID] {
        bonsplitController.treeSnapshot().orderedPaneIds.compactMap(UUID.init(uuidString:))
    }

    func selectedSurfaceId(inPaneId paneId: UUID) -> UUID? {
        bonsplitController.selectedTab(inPane: PaneID(id: paneId))?.id.uuid
    }

    func surfaceIdsInTabOrder(inPaneId paneId: UUID) -> [UUID] {
        bonsplitController.tabs(inPane: PaneID(id: paneId)).map(\.id.uuid)
    }

    func panelId(forSurfaceId surfaceId: UUID) -> UUID? {
        panelIdFromSurfaceId(TabID(uuid: surfaceId))
    }

    func panelExists(_ panelId: UUID) -> Bool {
        panels[panelId] != nil
    }

    var allPanelIds: [UUID] {
        Array(panels.keys)
    }

    var firstSidebarOrderedPanelId: UUID? {
        sidebarOrderedPanelIds().first
    }

    var lastOrderedPanelIds: [UUID] {
        get { paneTree.lastOrderedPanelIds }
        set { paneTree.lastOrderedPanelIds = newValue }
    }

    func bumpPaneLayoutVersion() {
        paneLayoutVersion &+= 1
    }
}
