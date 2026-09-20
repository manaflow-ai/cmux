import Bonsplit
import CmuxCore
import Foundation

extension Workspace {
    /// Captures split geometry and stable panel IDs for Mac workspace-layout requests.
    func deviceWorkspaceLayoutSnapshot() -> DeviceWorkspaceLayoutNode? {
        deviceLayoutNode(bonsplitController.treeSnapshot())
    }

    private func deviceLayoutNode(_ node: ExternalTreeNode) -> DeviceWorkspaceLayoutNode? {
        switch node {
        case .pane(let pane):
            return .pane(
                id: pane.id,
                surfaceIDs: pane.tabs.compactMap { deviceLayoutPanelID($0.id) },
                selectedSurfaceID: pane.selectedTabId.flatMap { deviceLayoutPanelID($0) }
            )
        case .split(let split):
            guard let direction = DeviceWorkspaceLayoutNode.Direction(rawValue: split.orientation),
                  split.dividerPosition.isFinite,
                  let first = deviceLayoutNode(split.first),
                  let second = deviceLayoutNode(split.second) else { return nil }
            return .split(direction: direction, ratio: split.dividerPosition, first: first, second: second)
        }
    }

    private func deviceLayoutPanelID(_ tabID: String) -> String? {
        guard let id = UUID(uuidString: tabID) else { return nil }
        return panelIdFromSurfaceId(TabID(id: id))?.uuidString
    }
}
