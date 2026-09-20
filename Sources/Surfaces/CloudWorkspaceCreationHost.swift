import AppKit
import Bonsplit
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

    func reserve(title: String, machine: SurfaceMachineID, focus: Bool) throws -> CloudTerminalPaneReservation {
        guard let manager,
              let workspace = manager.addWorkspaceIfActive(
                title: title, titleSource: .auto, initialSurface: .cloudVMLoading,
                inheritWorkingDirectory: false, select: false, autoWelcomeIfNeeded: false
              ) else { throw CancellationError() }
        guard let starter = workspace.focusedPanelId,
              let pane = workspace.paneId(forPanelId: starter),
              let reservation = workspace.reserveCloudTerminalPane(
                machine: machine, at: .tab(workspaceID: workspace.id, paneID: pane.id.uuidString, index: nil),
                focus: false
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
        }
        return reservation
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

    func discard(_ reservation: CloudTerminalPaneReservation, catalog: SurfaceCatalog) {
        guard let workspace = Workspace.liveWorkspace(id: reservation.workspaceID),
              workspace.panels[reservation.panelID] != nil else { return }
        catalog.endProjections(panelID: reservation.panelID, reason: .replaced)
        workspace.cancelReservedCloudTerminalPane(panelID: reservation.panelID)
        if workspace.panels.count == 1, let owner = workspace.owningTabManager ?? manager {
            _ = owner.closeWorkspaceNonInteractively(workspace, recordHistory: false, allowPinned: true)
        } else {
            // User-added panes belong to the user, even if this create fails.
            catalog.withProjectionEndReason(for: [reservation.panelID], reason: .replaced) {
                _ = workspace.closePanel(reservation.panelID, force: true)
            }
        }
    }
}
