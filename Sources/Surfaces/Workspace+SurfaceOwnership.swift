import CmuxCloud
import AppKit
import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

extension Workspace {
    var surfaceOwnershipPolicy: SurfaceOwnershipPolicy {
        SurfaceOwnershipPolicy(cloudMachine: cloudVMBinding.map { SurfaceMachineID(rawValue: $0.vmID) } ?? cloudVMID.map(SurfaceMachineID.cloud))
    }

    /// A pane's projection or remote transport owns its machine, never its title
    /// or merely the workspace it happens to be displayed in.
    func machineOwningSurface(_ panelID: UUID, catalog: SurfaceCatalog? = nil) -> SurfaceMachineID? {
        let catalog = catalog ?? SurfaceCatalog.shared
        guard panels[panelID] != nil else { return nil }
        if let machine = catalog.machineOwningPanel(panelID), !machine.isLocal { return machine }
        if let resource = (panels[panelID] as? DeferredBrowserPanel)?.sessionPanelSnapshot.browser?.cloudResource { return resource.machine }
        if let reservation = cloudPendingCreations[panelID] { return reservation.machine }
        if activeRemoteTerminalSurfaceIds.contains(panelID),
           let machine = remoteConfiguration?.managedCloudVMID {
            return .cloud(machine)
        }
        return panels[panelID]?.transferredSurfaceMachine ?? .local
    }

    func surfaceDropRejection(
        _ transfer: PaneDragTransfer,
        source: PaneTransferSourceResolver.Source
    ) -> SurfaceTransferRejection? {
        guard surfaceOwnershipPolicy.cloudMachine != nil else { return nil }
        switch source {
        case .surfaceResources(let group):
            return SurfaceCatalog.shared.ownershipRejection(for: group.resources, policy: surfaceOwnershipPolicy)
        case .surface:
            guard transfer.isFromCurrentProcess else { return surfaceOwnershipPolicy.rejection(for: nil) }
            // A surface already in this workspace crosses no machine boundary when
            // it is reordered or split within it. Rejecting it here put the Cloud
            // drop gate over the workspace's own tab strips and blocked tab drags.
            if panelIdFromSurfaceId(TabID(uuid: transfer.tabId)) != nil { return nil }
            return surfaceOwnershipPolicy.rejection(for: AppDelegate.shared?.machineOwningBonsplitTab(transfer.tabId))
        case .vaultSession, .filePreview, .rightSidebarTool:
            return surfaceOwnershipPolicy.rejection(for: .local)
        }
    }

    func surfaceDropRejection(_ transfer: TabDragTransfer) -> SurfaceTransferRejection? {
        let paneTransfer = PaneDragTransfer(tabDragTransfer: transfer)
        guard let source = PaneTransferSourceResolver().source(for: paneTransfer) else {
            return surfaceOwnershipPolicy.rejection(for: nil)
        }
        return surfaceDropRejection(paneTransfer, source: source)
    }

    func acceptsSurface(from source: Workspace, panelID: UUID) -> Bool {
        !isRetiredFromOwningTabManager
            && surfaceOwnershipPolicy.rejection(for: source.machineOwningSurface(panelID)) == nil
    }

    func acceptsDetachedSurface(_ transfer: DetachedSurfaceTransfer) -> Bool {
        // A failed transfer must be able to restore the exact source, including
        // pre-existing mixed workspaces created before ownership was enforced.
        if transfer.origin == .workspace(id) { return true }
        let machine = transfer.surfaceMachine
            ?? SurfaceCatalog.shared.machineOwningPanel(transfer.panelId)
            ?? transfer.remoteRelayNamespaceConfiguration?.managedCloudVMID.map(SurfaceMachineID.cloud)
            ?? transfer.remoteCleanupConfiguration?.managedCloudVMID.map(SurfaceMachineID.cloud)
            ?? .local
        return surfaceOwnershipPolicy.rejection(for: machine) == nil
    }
}
