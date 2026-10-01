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
                                    kind: SurfaceOwnershipKind.of(workspace.panels[panelID]))
        case .dock(let dock, let panelID):
            return policy.rejection(for: dock.machineOwningSurface(panelID),
                                    kind: SurfaceOwnershipKind.of(dock.panels[panelID]))
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

/// Resource identity takes precedence over the view used to render it: a remote
/// display is carried by a browser panel, but is not a portable browser tab.
@MainActor
enum SurfaceOwnershipKind {
    static func of(_ panel: (any Panel)?) -> SurfaceResourceKind? {
        guard let panel else { return nil }
        if let resource = SurfaceCatalog.shared.projectionRecord(forPanel: panel.id)?.resource, !resource.machine.isLocal {
            return resource.kind
        }
        if let deferred = panel as? DeferredBrowserPanel {
            let saved = deferred.sessionPanelSnapshot.browser
            return saved?.cloudResource?.kind
                ?? (saved?.urlString.flatMap(URL.init(string:))?.path == "/vnc.html" ? .display : .browser)
        }
        if let browser = panel as? BrowserPanel {
            return browser.cloudAccess.resourceID?.kind
                ?? (browser.currentURL?.path == "/vnc.html" ? .display : .browser)
        }
        return panel.panelType == .terminal ? .terminal : nil
    }
}
