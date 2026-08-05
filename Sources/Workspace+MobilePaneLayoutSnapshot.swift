import CMUXMobileCore
import CmuxWorkspaces
import Foundation

extension Workspace {
    /// Captures one canonical mobile pane-layout snapshot from the workspace.
    func mobileWorkspaceLayoutSnapshot() -> MobileWorkspaceLayout {
        let tree = bonsplitController.treeSnapshot()
        let serializer = MobileWorkspaceLayoutSerializer()
        var surfacesByTabID: [String: MobileWorkspaceLayoutSurfaceMetadata] = [:]
        for tab in serializer.tabs(in: tree) {
            let panelID = UUID(uuidString: tab.id).flatMap { panelId(forSurfaceId: $0) }
            let panel = panelID.flatMap { panels[$0] }
            surfacesByTabID[tab.id] = MobileWorkspaceLayoutSurfaceMetadata(
                id: panelID?.uuidString ?? tab.id,
                type: panel?.panelType.rawValue ?? PanelType.terminal.rawValue,
                title: panelID.flatMap { panelTitle(panelId: $0) }
                    ?? panel?.displayTitle
                    ?? tab.title
            )
        }
        return serializer.layout(
            tree: tree,
            version: paneLayoutVersion,
            focusedPaneID: bonsplitController.focusedPaneId?.id.uuidString,
            surfacesByTabID: surfacesByTabID
        )
    }
}
