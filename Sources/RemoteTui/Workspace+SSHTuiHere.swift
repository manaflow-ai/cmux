import Bonsplit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

@MainActor
extension Workspace {
    /// Admission is repeated after authentication: a stale caller may not
    /// replace a terminal that moved or became remote while SSH was connecting.
    func canBeginSSHTuiHereSession(panelID: UUID) -> Bool {
        !isRetiredFromOwningTabManager && sshTuiHereSession == nil && remoteConfiguration == nil
            && cloudVMBinding == nil && cloudVMID == nil && !isRemoteTmuxMirror
            && layoutMode != .canvas && panels.count == 1 && bonsplitController.allPaneIds.count == 1
            && cloudPendingCreations.isEmpty && terminalPanel(for: panelID)?.surface.ioMode == .exec
            && machineOwningSurface(panelID)?.isLocal == true && paneId(forPanelId: panelID) != nil
    }

    /// Insert the remote placeholder before parking the shell so Bonsplit never
    /// empties (and replaces) the caller's pane. No local PTY is torn down.
    func beginSSHTuiHereSession(
        panelID: UUID, machine: SurfaceMachineID, operationID: UUID
    ) throws -> SSHTuiHereSession {
        guard canBeginSSHTuiHereSession(panelID: panelID), machine.isSSH,
              let pane = paneId(forPanelId: panelID), let local = terminalPanel(for: panelID) else {
            throw CloudDiagnosticFailure.placement
        }
        let localDirectory = currentDirectory
        let originalTitle = customTitle
        let originalTitleSource = effectiveCustomTitleSource ?? .user
        guard let reservation = reserveCloudTerminalPane(
            machine: machine, at: .tab(workspaceID: id, paneID: pane.id.uuidString, index: nil), focus: false
        ) else { throw CloudDiagnosticFailure.placement }
        guard let transfer = detachSurface(panelId: panelID) else {
            _ = closePanel(reservation.panelID, force: true)
            throw CloudDiagnosticFailure.placement
        }
        local.unfocus()
        local.hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: local.hostedView)
        // Transfers normally move a projection to another workspace. This one
        // is parked outside the visible catalog until its original pane returns.
        SurfaceCatalog.shared.endProjections(panelID: panelID, reason: .replaced)
        let session = SSHTuiHereSession(
            operationID: operationID, paneID: pane, originalTransfer: transfer,
            reservation: reservation, localDirectory: localDirectory,
            originalTitle: originalTitle, originalTitleSource: originalTitleSource
        )
        sshTuiHereSession = session
        reservation.cancel = { [weak self, weak session] in
            guard let self, let session, self.sshTuiHereSession === session else { return }
            self.finishSSHTuiHereSession(rollback: true)
        }
        return session
    }

    /// Detaches this visit's remote views, then returns to the retained local
    /// shell. The shared carrier and daemon-owned workloads remain alive.
    @discardableResult
    func finishSSHTuiHereSession(rollback: Bool = false) -> Bool {
        guard let session = sshTuiHereSession else { return false }
        guard !isRetiredFromOwningTabManager else {
            discardSSHTuiHereSession()
            return true
        }
        guard let destination = bonsplitController.allPaneIds.first(where: { $0 == session.paneID })
            ?? paneId(forPanelId: session.reservation.panelID) ?? bonsplitController.allPaneIds.first else {
            return false
        }
        // Retire ownership before cancellation callbacks or panel-map observers
        // can reenter this path. Clearing the binding also fences reconciliation.
        sshTuiHereSession = nil
        session.cancelCallerObservation()
        session.connectionTask?.cancel()
        session.connectionTask = nil
        sshTuiConnectionAttemptID = nil
        let catalog = SurfaceCatalog.shared
        let remotePanels = Set(catalog.projections.filter {
            $0.workspaceID == id && $0.resource.machine == session.reservation.machine
        }.map(\.panelID)).union(cloudPendingCreations.values.filter {
            $0.machine == session.reservation.machine
        }.map(\.panelID)).union([session.reservation.panelID])
        cloudVMBinding = nil
        remoteConfiguration = nil
        // No configuration remains to close a shared OpenSSH ControlMaster.
        disconnectRemoteConnection(clearConfiguration: true)
        currentDirectory = session.localDirectory
        guard attachDetachedSurface(session.originalTransfer, inPane: destination, focus: false) != nil else {
            // Never destroy the only return shell if a concurrent layout change
            // prevents reattachment. A later disconnect can retry the transfer.
            sshTuiHereSession = session
            return true
        }
        for panelID in remotePanels {
            catalog.endProjections(panelID: panelID, reason: .replaced)
            if panels[panelID] != nil {
                catalog.withProjectionEndReason(for: [panelID], reason: .replaced) {
                    _ = closePanel(panelID, force: true)
                }
            }
        }
        if (rollback && customTitle == session.requestedTitle) || effectiveCustomTitleSource == .remote {
            let title = rollback ? session.originalTitle : (session.requestedTitle ?? session.originalTitle)
            let source = session.requestedTitle != nil && !rollback ? CustomTitleSource.user : session.originalTitleSource
            // Automatic titles cannot replace an authoritative remote title.
            // Retire that authority before restoring the original provenance.
            if source == .auto { setCustomTitle(nil) }
            if let manager = owningTabManager {
                manager.setCustomTitle(tabId: id, title: title, source: source, propagateToCloud: false)
            } else {
                setCustomTitle(title, source: source)
            }
        }
        focusPanel(session.originalTransfer.panelId)
        return true
    }

    /// Workspace/window teardown ends both local ownerships without resurrecting
    /// the workspace. Used before reservation cancellation can request a return.
    func discardSSHTuiHereSession() {
        guard let session = sshTuiHereSession else { return }
        sshTuiHereSession = nil
        session.cancelCallerObservation()
        sshTuiConnectionAttemptID = nil
        session.connectionTask?.cancel()
        session.connectionTask = nil
        session.originalTransfer.panel.close()
        TerminalController.shared.cleanupSurfaceState(surfaceIds: [session.originalTransfer.panelId])
    }
}
