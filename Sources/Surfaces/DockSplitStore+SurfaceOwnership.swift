import CmuxCloud
import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

extension DockSplitStore {
    var surfaceOwnershipPolicy: SurfaceOwnershipPolicy {
        scope == .workspace ? (Workspace.liveWorkspace(id: workspaceId)?.surfaceOwnershipPolicy ?? .init(cloudMachine: nil)) : .init(cloudMachine: nil)
    }

    func acceptsUnownedBrowserURL(_ url: URL?) -> Bool {
        if scope == .global { return true }
        guard url?.path == "/vnc.html" else { return true }
        return surfaceOwnershipPolicy.rejection(for: nil) == nil
    }

    func surfaceDropRejection(_ transfer: PaneDragTransfer, source: PaneTransferSourceResolver.Source) -> SurfaceTransferRejection? {
        switch source {
        case .surfaceResources(let group):
            return SurfaceCatalog.shared.ownershipRejection(for: group.resources, policy: surfaceOwnershipPolicy)
        case .surface:
            guard transfer.isFromCurrentProcess else { return surfaceOwnershipPolicy.rejection(for: nil) }
            // A Dock surface split or reordered within this Dock stays on its machine.
            if surfaceIdToPanelId[TabID(uuid: transfer.tabId)] != nil { return nil }
            return surfaceOwnershipPolicy.rejection(for: AppDelegate.shared?.machineOwningBonsplitTab(transfer.tabId))
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
            return scope == .global || surfaceOwnershipPolicy.rejection(for: nil) == nil
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

/// Whether a terminal's shell runs on another machine, wherever the terminal
/// is hosted: a workspace's split tree or a Dock. Predicted echo only runs for
/// these terminals.
@MainActor
enum TerminalRemoteMachineClassification {
    static func runsOnAnotherMachine(surfaceID: UUID, workspaceID: UUID) -> Bool {
        if let dock = DockSplitStore.liveStores.first(where: { $0.containsPanel(surfaceID) }) {
            return dock.terminalRunsOnAnotherMachine(surfaceID)
        }
        return AppDelegate.shared?.workspaceFor(tabId: workspaceID)?
            .terminalRunsOnAnotherMachine(surfaceID) ?? false
    }
}

extension DockSplitStore {
    /// A Dock hosts a remote terminal only by transfer: a Cloud or SSH
    /// projection, or a remote PTY surface moved in from a remote workspace.
    func terminalRunsOnAnotherMachine(_ panelID: UUID) -> Bool {
        if detachedSurfaceTransfersByPanelId[panelID]?.isRemoteTerminal == true { return true }
        guard let machine = machineOwningSurface(panelID) else { return false }
        return !machine.isLocal
    }
}
