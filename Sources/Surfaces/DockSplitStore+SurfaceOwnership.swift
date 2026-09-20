import Foundation

extension DockSplitStore {
    var surfaceOwnershipPolicy: SurfaceOwnershipPolicy {
        scope == .workspace ? (Workspace.liveWorkspace(id: workspaceId)?.surfaceOwnershipPolicy ?? .init(cloudMachine: nil)) : .init(cloudMachine: nil)
    }

    func acceptsUnownedBrowserURL(_ url: URL?) -> Bool {
        guard url?.path == "/vnc.html" else { return true }
        return scope != .global && surfaceOwnershipPolicy.rejection(for: nil) == nil
    }

    func surfaceDropRejection(_ transfer: PaneDragTransfer, source: PaneTransferSourceResolver.Source) -> SurfaceTransferRejection? {
        switch source {
        case .surfaceResources(let group):
            return SurfaceCatalog.shared.ownershipRejection(for: group.resources, policy: surfaceOwnershipPolicy)
        case .surface:
            let machine = transfer.isFromCurrentProcess ? AppDelegate.shared?.machineOwningBonsplitTab(transfer.tabId) : nil
            return surfaceOwnershipPolicy.rejection(for: machine)
        case .vaultSession, .filePreview, .rightSidebarTool:
            return surfaceOwnershipPolicy.rejection(for: .local)
        }
    }

    func acceptsDetachedSurface(_ transfer: Workspace.DetachedSurfaceTransfer) -> Bool {
        if transfer.origin == .dock(workspaceId) { return true }
        return surfaceOwnershipPolicy.rejection(for: transfer.surfaceMachine
            ?? SurfaceCatalog.shared.machineOwningPanel(transfer.panelId)
            ?? transfer.panel.transferredSurfaceMachine) == nil
    }

    func acceptsRestoredDisplay(_ snapshot: SessionPanelSnapshot) -> Bool {
        if let resource = snapshot.browser?.cloudResource {
            return surfaceOwnershipPolicy.rejection(for: resource.machine) == nil
        }
        if let raw = snapshot.browser?.urlString, URL(string: raw)?.path == "/vnc.html" {
            return scope != .global && surfaceOwnershipPolicy.rejection(for: nil) == nil
        }
        return true
    }

    func machineOwningSurface(_ panelID: UUID) -> SurfaceMachineID? {
        guard panels[panelID] != nil else { return nil }
        if let machine = SurfaceCatalog.shared.machineOwningPanel(panelID), !machine.isLocal { return machine }
        if let resource = (panels[panelID] as? DeferredBrowserPanel)?.sessionPanelSnapshot.browser?.cloudResource { return resource.machine }
        return panels[panelID]?.transferredSurfaceMachine
            ?? detachedSurfaceTransfersByPanelId[panelID]?.surfaceMachine
            ?? .local
    }
}
