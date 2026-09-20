import Foundation

extension SurfaceCatalog {
    func projectionMatchesMaterializationDestination(_ projection: SurfaceProjection, _ destination: SurfaceDestination) -> Bool {
        guard projection.workspaceID == destination.workspaceID else { return false }
        switch destination {
        case .workspace: return true
        case .split: return false
        case .tab(_, let paneID, let index):
            guard let workspace = Workspace.liveWorkspace(id: projection.workspaceID),
                  workspace.paneId(forPanelId: projection.panelID)?.id.uuidString == paneID else { return false }
            return index == nil || workspace.indexInPane(forPanelId: projection.panelID) == index
        }
    }
}
