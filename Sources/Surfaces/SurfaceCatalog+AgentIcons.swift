import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Visits projections once per accepted catalog transaction, independent of
    /// the number of resources in a full snapshot. Missing resources clear icons.
    func syncCloudTerminalTabIcons(on machine: SurfaceMachineID, affected: Set<SurfaceResourceID>? = nil) {
        guard !machine.isLocal else { return }
        for projection in projections where projection.resource.machine == machine {
            if let affected, !affected.contains(projection.resource) { continue }
            syncCloudTerminalTabIcon(projection)
        }
    }

    func syncCloudTerminalTabIcon(_ projection: SurfaceProjection) {
        guard !projection.resource.machine.isLocal, projection.resource.kind == .terminal,
              let workspace = cloudWorkspaceRenameService.environment.workspace(projection.workspaceID),
              workspace.panels[projection.panelID] is TerminalPanel,
              let tabID = workspace.surfaceIdFromPanelId(projection.panelID),
              let tab = workspace.bonsplitController.tab(tabID) else { return }
        let asset = resources[projection.resource]?.terminalAgentIconAssetName
        guard tab.iconAsset != asset else { return }
        workspace.bonsplitController.updateTab(tabID, iconAsset: .some(asset))
    }

    /// A tab opened after its terminal's process title was set takes that
    /// title now; later titles arrive through remote-state reconciliation.
    func syncCloudTerminalTabTitle(_ projection: SurfaceProjection) {
        guard !projection.resource.machine.isLocal, projection.resource.kind == .terminal,
              let resource = resources[projection.resource],
              let workspace = cloudWorkspaceRenameService.environment.workspace(projection.workspaceID),
              workspace.panels[projection.panelID] != nil else { return }
        let title = resource.cloudProcessDisplayTitle
        guard workspace.panelTitles[projection.panelID] != title else { return }
        _ = workspace.updatePanelTitle(panelId: projection.panelID, title: title)
    }
}
