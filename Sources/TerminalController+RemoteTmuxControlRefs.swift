import Foundation

@MainActor
extension TerminalController {
    func v2RefreshRemoteTmuxAwarePaneAndSurfaceRefs(workspace: Workspace) {
        let panes = controlPaneSummaries(
            workspace: workspace,
            snapshot: workspace.bonsplitController.layoutSnapshot()
        )
        for pane in panes {
            _ = v2Ref(kind: .pane, uuid: pane.paneID)
            for surfaceID in pane.surfaceIDs {
                _ = v2Ref(kind: .surface, uuid: surfaceID)
            }
        }
    }
}
