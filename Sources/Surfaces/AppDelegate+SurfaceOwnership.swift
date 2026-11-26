import Bonsplit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

extension AppDelegate {
    func ownershipRejection(forBonsplitTab tabID: UUID, policy: SurfaceOwnershipPolicy) -> SurfaceTransferRejection? {
        guard let source = locateContainerSurface(tabId: tabID) else { return policy.rejection(for: nil) }
        switch source {
        case .workspace(_, let workspace, let panelID, _):
            return policy.rejection(for: workspace.machineOwningSurface(panelID),
                                    kind: surfaceResourceKind(for: workspace.panels[panelID]))
        case .dock(let dock, let panelID):
            return policy.rejection(for: dock.machineOwningSurface(panelID),
                                    kind: surfaceResourceKind(for: dock.panels[panelID]))
        }
    }

    func machineOwningBonsplitTab(_ tabID: UUID) -> SurfaceMachineID? {
        guard let source = locateContainerSurface(tabId: tabID) else { return nil }
        switch source {
        case .workspace(_, let workspace, let panelID, _):
            return workspace.machineOwningSurface(panelID)
        case .dock(let dock, let panelID):
            return dock.machineOwningSurface(panelID)
        }
    }
}

extension AppDelegate {
    /// Resource identity takes precedence over the view used to render it. A
    /// remote display is carried by a browser panel, but is not a portable tab.
    func surfaceResourceKind(for panel: (any Panel)?) -> SurfaceResourceKind? {
        guard let panel else { return nil }
        if let resource = SurfaceCatalog.shared.projectionRecord(forPanel: panel.id)?.resource {
            return resource.kind
        }
        if let deferred = panel as? DeferredBrowserPanel {
            return deferred.sessionPanelSnapshot.browser?.cloudResource?.kind
        }
        if let browser = panel as? BrowserPanel, let resource = browser.cloudAccess.resourceID {
            return resource.kind
        }
        return panel.panelType == .terminal ? .terminal : nil
    }
}
