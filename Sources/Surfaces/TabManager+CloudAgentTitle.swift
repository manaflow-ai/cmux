import Foundation

extension TabManager {
    /// Native agent titles use the exact Cloud placement's rename lane. Local
    /// terminals retain their OSC/process-title behavior. Explicit labels win in
    /// both cases, so a delayed hook cannot replace a user-selected name.
    @discardableResult
    func syncAgentTerminalTitle(
        tabId: UUID,
        panelId: UUID,
        title: String,
        catalog: SurfaceCatalog = .shared
    ) -> Bool {
        guard let workspace = workspacesById[tabId] else { return false }
        if workspace.cloudProjectedResource(forPanel: panelId, catalog: catalog)?.kind == .terminal {
            return workspace.setPanelCustomTitle(panelId: panelId, title: title, source: .auto, catalog: catalog)
        }
        return updatePanelTitle(tabId: tabId, panelId: panelId, title: title)
    }
}
