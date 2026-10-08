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

    /// Returns the machine identity for a terminal surface, including a pane
    /// owned by a nested remote-tmux window mirror.
    func sshClipboardMachine(
        for panelID: UUID,
        ownership: SSHClipboardWriteSurfaceOwnershipIndex
    ) -> SurfaceMachineID? {
        if let machine = ownership.machine(for: panelID) {
            return machine
        }

        let mirrorContainerID = remoteTmuxWindowMirrors.first(where: { _, mirror in
            mirror.panelsByPaneId.values.contains { $0.id == panelID }
        })?.key
        if let containerID = mirrorContainerID {
            if let machine = ownership.machine(for: containerID) {
                return machine
            }
            if let configuration = remoteConfiguration,
               configuration.transport == .ssh {
                return .ssh(SSHTuiConnection(configuration: configuration).identityDigest)
            }
        }

        guard let panel = panels[panelID] else { return nil }
        if let configuration = remoteConfiguration,
           configuration.transport == .ssh,
           panel.surface.ioMode == .manualMirror {
            return .ssh(SSHTuiConnection(configuration: configuration).identityDigest)
        }
        if let resource = (panel as? DeferredBrowserPanel)?.sessionPanelSnapshot.browser?.cloudResource {
            return resource.machine
        }
        if let reservation = cloudPendingCreations[panelID] {
            return reservation.machine
        }
        if activeRemoteTerminalSurfaceIds.contains(panelID),
           let machine = remoteConfiguration?.managedCloudVMID {
            return .cloud(machine)
        }
        return panel.transferredSurfaceMachine ?? .local
    }

    /// Reconciles every live terminal surface owned by `machine` from the
    /// injected trust store, including panes outside `Workspace.panels`.
    func applySSHClipboardWritePermission(
        for machine: SurfaceMachineID,
        ownership: SSHClipboardWriteSurfaceOwnershipIndex
    ) {
        let allowed = sshClipboardWriteTrustStore.allowsRemoteClipboardWrites(for: machine)
        for panel in panels.values.compactMap({ $0 as? TerminalPanel })
        where sshClipboardMachine(for: panel.id, ownership: ownership) == machine {
            panel.surface.setAllowsRemoteClipboardWrites(allowed)
        }

        for (containerID, mirror) in remoteTmuxWindowMirrors
        where sshClipboardMachine(for: containerID, ownership: ownership) == machine {
            for panel in mirror.panelsByPaneId.values {
                panel.surface.setAllowsRemoteClipboardWrites(allowed)
            }
        }
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
            guard let app = AppDelegate.shared else { return surfaceOwnershipPolicy.rejection(for: nil) }
            return app.ownershipRejection(forBonsplitTab: transfer.tabId, policy: surfaceOwnershipPolicy)
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
            && surfaceOwnershipPolicy.rejection(for: source.machineOwningSurface(panelID),
                                                kind: AppDelegate.shared?.surfaceResourceKind(for: source.panels[panelID])) == nil
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
        return surfaceOwnershipPolicy.rejection(for: machine, kind: AppDelegate.shared?.surfaceResourceKind(for: transfer.panel)) == nil
    }
}
