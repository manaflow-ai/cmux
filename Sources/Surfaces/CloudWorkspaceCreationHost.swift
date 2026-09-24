import AppKit
import Bonsplit
import CmuxTerminal
import Foundation

/// Captures the initiating window before creation suspends; completion never reselects it.
@MainActor
struct CloudWorkspaceCreationHost {
    weak var manager: TabManager?
    let selectedWorkspaceID: UUID?

    init(manager: TabManager) {
        self.manager = manager
        selectedWorkspaceID = manager.selectedTabId
    }

    var isAvailable: Bool { manager?.isFinalizedForWindowClose == false }

    func reserve(
        title: String,
        machine: SurfaceMachineID,
        receipt: SurfaceWorkspaceCreationReceipt? = nil,
        focus: Bool
    ) throws -> CloudTerminalPaneReservation {
        guard let manager,
              let workspace = manager.addWorkspaceIfActive(
                title: title, titleSource: .auto, initialSurface: .cloudVMLoading,
                inheritWorkingDirectory: false, select: false, autoWelcomeIfNeeded: false
              ) else { throw CancellationError() }
        guard let starter = workspace.focusedPanelId,
              let pane = workspace.paneId(forPanelId: starter),
              let reservation = workspace.reserveCloudTerminalPane(
                machine: machine, at: .tab(workspaceID: workspace.id, paneID: pane.id.uuidString, index: nil),
                focus: false,
                sourcePlacement: CloudTerminalSourcePlacement(machine: machine, remoteWorkspaceID: receipt?.workspace.id, remoteTabID: nil),
                attachmentPlacement: receipt.flatMap { receipt in
                    guard let terminal = receipt.terminal else { return nil }
                    return SurfaceResourcePlacement(resource: terminal.id, remoteView: terminal.remoteViews?.first { $0.workspace.id == receipt.workspace.id }, remoteWorkspaceID: receipt.workspace.id)
                }
              ) else {
            manager.closeWorkspace(workspace, recordHistory: false)
            throw CancellationError()
        }
        // The loading scaffold never runs a local shell. Replace it in this same
        // actor turn so the first visible terminal already buffers remote input.
        _ = workspace.closePanel(starter, force: true)
        if focus, manager.selectedTabId == selectedWorkspaceID, manager.window?.isKeyWindow != false {
            manager.selectWorkspace(workspace)
            SurfacePaneFactory.focus(panelID: reservation.panelID, in: workspace.id)
            workspace.terminalPanel(for: reservation.panelID)?.surface.requestInputDemandSurfaceStartIfNeeded()
        }
        return reservation
    }

    /// Publishes the remote identity and final title after local admission.
    /// User navigation or a rename that happened while the request awaited
    /// the provider always wins over this automatic title update.
    func updateReservation(
        _ reservation: CloudTerminalPaneReservation,
        receipt: SurfaceWorkspaceCreationReceipt,
        generatedTitle: String,
        catalog: SurfaceCatalog
    ) {
        reservation.updateRemoteWorkspaceID(receipt.workspace.id)
        guard let workspace = Workspace.liveWorkspace(id: reservation.workspaceID),
              workspace.effectiveCustomTitleSource != .user,
              let manager = workspace.owningTabManager ?? manager else { return }
        _ = manager.setCustomTitle(
            tabId: reservation.workspaceID,
            title: generatedTitle,
            source: .remote,
            propagateToRemoteTmux: false,
            propagateToCloud: false,
            catalog: catalog
        )
    }

    func isLive(_ reservation: CloudTerminalPaneReservation) -> Bool {
        guard let workspace = Workspace.liveWorkspace(id: reservation.workspaceID) else { return false }
        return !workspace.isRetiredFromOwningTabManager
            && workspace.cloudPendingCreations[reservation.panelID] === reservation
    }

    func complete(_ reservation: CloudTerminalPaneReservation, projection: SurfaceProjection) {
        Workspace.liveWorkspace(id: reservation.workspaceID)?.completeReservedCloudTerminalPane(
            reservation, adoptedPanelID: projection.panelID
        )
    }

    func restart(_ reservation: CloudTerminalPaneReservation) {
        reservation.creationReceipt.beginAttempt()
        Workspace.liveWorkspace(id: reservation.workspaceID)?.restartReservedCloudTerminalPane(reservation)
    }

    func fail(_ reservation: CloudTerminalPaneReservation, error: Error) {
        reservation.creationReceipt.finish(.failure(error))
        Workspace.liveWorkspace(id: reservation.workspaceID)?.failReservedCloudTerminalPane(reservation, error: error)
    }

    func discard(_ reservation: CloudTerminalPaneReservation, catalog: SurfaceCatalog) {
        guard let workspace = Workspace.liveWorkspace(id: reservation.workspaceID),
              workspace.panels[reservation.panelID] != nil else { return }
        catalog.endProjections(panelID: reservation.panelID, reason: .replaced)
        workspace.cancelReservedCloudTerminalPane(panelID: reservation.panelID)
        if workspace.panels.count == 1,
           workspace.effectiveCustomTitleSource != .user,
           let owner = workspace.owningTabManager ?? manager {
            _ = owner.closeWorkspaceNonInteractively(workspace, recordHistory: false, allowPinned: true)
        } else {
            // User-added panes and user-renamed workspaces belong to the user,
            // even if this create fails.
            catalog.withProjectionEndReason(for: [reservation.panelID], reason: .replaced) {
                _ = workspace.closePanel(reservation.panelID, force: true)
            }
        }
    }
}
