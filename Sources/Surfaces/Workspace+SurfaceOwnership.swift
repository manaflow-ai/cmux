import CmuxCloud
import AppKit
import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

extension Workspace {
    /// The configured cmux-tui SSH identity for this workspace, when present.
    var configuredSSHClipboardMachine: SurfaceMachineID? {
        guard let configuration = remoteConfiguration,
              configuration.transport == .ssh else { return nil }
        return .ssh(SSHTuiConnection(configuration: configuration).identityDigest)
    }

    /// The SSH identity for a plain `ssh-tmux` mirror, when this workspace is
    /// backed by one. Plain mirrors do not have a ``remoteConfiguration``;
    /// derive the same endpoint digest from the mirror host that the trust menu
    /// and newly-created manual panes use.
    var remoteTmuxSSHClipboardMachine: SurfaceMachineID? {
        guard let host = remoteTmuxSessionMirror?.host,
              host.transport == .ssh else { return nil }
        let configuration = WorkspaceRemoteConfiguration(
            destination: host.destination,
            port: host.port,
            identityFile: host.identityFile,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        return .ssh(SSHTuiConnection(configuration: configuration).identityDigest)
    }

    /// Whether a new pane created by this plain `ssh-tmux` mirror may emit OSC 52.
    var allowsRemoteTmuxClipboardWrites: Bool {
        guard let machine = remoteTmuxSSHClipboardMachine else { return false }
        return sshClipboardWriteTrustStore.allowsRemoteClipboardWrites(for: machine)
    }

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

        // Optimistic SSH cmux-tui panes are owned before their catalog
        // projection/provider session exists. Preserve that exact reservation
        // identity even when they are inserted into another remote workspace.
        if let reservation = cloudPendingCreations[panelID] {
            return reservation.machine
        }

        // A live cmux-tui session can briefly outlive its catalog projection
        // while a restored or moved pane is being attached. Use the provider's
        // machine identity only for that live session; an arbitrary manual
        // mirror must not inherit the workspace's SSH configuration.
        if let session = tuiMirrorSession(for: panelID) {
            let machine = SurfaceMachineID(rawValue: session.machineID)
            if machine.isSSH {
                return machine
            }
        }

        // A window container remains an owner even when its terminal panel
        // has retired. Catalog ownership above takes precedence over its host.
        if remoteTmuxWindowMirrors[panelID] != nil {
            return remoteTmuxSSHClipboardMachine
        }

        guard let panel = panels[panelID] else {
            // Inner panes are mirror-owned, not Workspace.panels entries. This
            // lookup is needed for a single context-menu target, never per
            // ordinary panel in a batch propagation pass.
            guard let containerID = remoteTmuxWindowMirrors.first(where: { _, mirror in
                mirror.panelsByPaneId.values.contains { $0.id == panelID }
            })?.key else { return nil }
            return ownership.machine(for: containerID) ?? remoteTmuxSSHClipboardMachine
        }
        if let terminal = panel as? TerminalPanel,
           terminal.surface.ioMode == .manualMirror {
            // An unprojected generic/device mirror cannot borrow the SSH
            // identity of the workspace it happens to be displayed in.
            return panel.transferredSurfaceMachine
        }
        if let resource = (panel as? DeferredBrowserPanel)?.sessionPanelSnapshot.browser?.cloudResource {
            return resource.machine
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

        for mirror in remoteTmuxWindowMirrors.values
        where mirror.panelsByPaneId.values.contains(where: {
            sshClipboardMachine(for: $0.id, ownership: ownership) == machine
        }) {
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
