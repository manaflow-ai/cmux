import CmuxCloud
import Bonsplit
import CmuxRemoteSession
import CmuxSurfaceCatalogModel
import CmuxTerminal
import Foundation

/// Optimistic Cloud terminal creation: the pane appears the moment the user asks
/// for it, the machine's terminal is created behind it, and the pane is adopted
/// when the attachment resolves.
///
/// One mutation path serves every entrypoint (⌘D/⌘⇧D/⌘T, the pane-divider split
/// button, the Cloud sidebar). The reservation records the pending state under a
/// request id; success reconciles from the authoritative projection, and failure
/// is shown inside the pane with Retry, never as a separate "starting" surface.
@MainActor
extension Workspace {
    /// Returns the optimistic pane reserved for a provider's in-flight terminal.
    /// Device layout reconciliation uses it to adopt the authoritative terminal
    /// in its final pane instead of projecting it through the focused tab first.
    func pendingCloudTerminalReservation(
        machine: SurfaceMachineID,
        remoteWorkspaceID: String
    ) -> CloudTerminalPaneReservation? {
        cloudPendingCreations.values.first { reservation in
            reservation.machine == machine
                && reservation.remoteWorkspaceID == remoteWorkspaceID
        }
    }

    /// The Bonsplit pane currently occupied by an optimistic reservation.
    func pendingCloudTerminalPane(
        machine: SurfaceMachineID,
        remoteWorkspaceID: String
    ) -> PaneID? {
        guard let reservation = pendingCloudTerminalReservation(
            machine: machine, remoteWorkspaceID: remoteWorkspaceID
        ) else { return nil }
        return paneId(forPanelId: reservation.panelID)
    }

    /// Hands a device provider the native pane without requiring a Cloud
    /// attachment object. Device mirrors share the optimistic reservation path,
    /// but their attachment status has a different type from Cloud VMs.
    func adoptPendingDeviceTerminalPane(
        _ reservation: CloudTerminalPaneReservation,
        machine: SurfaceMachineID,
        remoteWorkspaceID: String
    ) -> (workspaceID: UUID, panelID: UUID, surface: TerminalSurface)? {
        guard reservation.machine == machine,
              reservation.remoteWorkspaceID == remoteWorkspaceID,
              cloudPendingCreations[reservation.panelID] === reservation,
              let panel = panels[reservation.panelID] as? TerminalPanel,
              panel.surface.ioMode == .manualMirror else { return nil }
        cloudPendingCreations.removeValue(forKey: reservation.panelID)
        return (id, panel.id, panel.surface)
    }

    func reserveRestoredCloudTerminalPane(
        snapshot: SessionPanelSnapshot,
        projection: SurfaceProjectionRecord,
        inPane pane: PaneID
    ) -> UUID? {
        guard projection.resource.kind == .terminal,
              !projection.resource.machine.isLocal else { return nil }
        let relay = CloudOptimisticInputRelay()
        guard let panel = makeRemoteTmuxPanePanel(
            onInput: { input in relay.send(input) },
            keyNameResolver: { RemoteTmuxKeyName(inputEvent: $0)?.value }
        ) else { return nil }
        panel.surface.setManualIONoReflow(false)
        do {
            let panelID = try insertCloudManualMirrorPanel(
                panel,
                at: .tab(workspaceID: id, paneID: pane.id.uuidString, index: nil),
                focus: false,
                isLoading: false
            )
            applySessionPanelMetadata(snapshot, toPanelId: panelID)
            cloudPendingCreations[panelID] = CloudTerminalPaneReservation(
                workspaceID: id,
                panelID: panelID,
                machine: projection.resource.machine,
                attachmentPlacement: SurfaceResourcePlacement(
                    resource: projection.resource,
                    remoteWorkspaceID: projection.remoteWorkspaceID,
                    remoteTabID: projection.remoteTabID
                ),
                inputRelay: relay
            )
            return panelID
        } catch {
            return nil
        }
    }

    /// Inserts the pane a Cloud terminal will occupy before the machine has created it.
    /// Returns nil when the destination no longer exists.
    func reserveCloudTerminalPane(
        machine: SurfaceMachineID,
        at destination: SurfaceDestination,
        focus: Bool,
        sourcePlacement: CloudTerminalSourcePlacement? = nil,
        attachmentPlacement: SurfaceResourcePlacement? = nil
    ) -> CloudTerminalPaneReservation? {
        guard !isRetiredFromOwningTabManager,
              sourcePlacement.map({ $0.machine == machine }) ?? true,
              attachmentPlacement.map({ $0.resource.machine == machine }) ?? true,
              surfaceOwnershipPolicy.rejection(for: machine) == nil else { return nil }
        let relay = CloudOptimisticInputRelay()
        guard let panel = makeRemoteTmuxPanePanel(
            onInput: { input in relay.send(input) },
            keyNameResolver: { RemoteTmuxKeyName(inputEvent: $0)?.value }
        ) else { return nil }
        panel.surface.setManualIONoReflow(false)
        let reservation = CloudTerminalPaneReservation(
            workspaceID: id, panelID: panel.id, machine: machine,
            sourcePlacement: sourcePlacement, attachmentPlacement: attachmentPlacement, inputRelay: relay
        )
        // Insertion can synchronously publish focus/selection. Establish Cloud
        // identity first so a reentrant action cannot observe a local surface.
        cloudPendingCreations[panel.id] = reservation
        do {
            _ = try insertCloudManualMirrorPanel(panel, at: destination, focus: focus, isLoading: false)
        } catch {
            cloudPendingCreations.removeValue(forKey: panel.id)
            relay.discard()
            panel.close()
            return nil
        }
        guard cloudPendingCreations[panel.id] === reservation else { return nil }
        if focus { panel.surface.requestInputDemandSurfaceStartIfNeeded() }
        return reservation
    }

    /// Binds a resolved attachment to the reserved pane. Returns nil when the
    /// user already closed the pane, in which case the caller cancels.
    func adoptReservedCloudTerminalPane(
        _ reservation: CloudTerminalPaneReservation,
        onResize: @escaping @MainActor @Sendable (TerminalSurfaceRawSizingSample) -> Void,
        onRuntimeReady: @escaping @MainActor @Sendable () -> Void,
        onFocus: @escaping @MainActor @Sendable () -> Void,
        attachment: CloudTerminalAttachmentStatus
    ) -> (workspaceID: UUID, panelID: UUID, surface: TerminalSurface)? {
        guard !isRetiredFromOwningTabManager,
              cloudPendingCreations[reservation.panelID] === reservation,
              attachment.machineID == reservation.machine.tuiMachineID,
              let panel = panels[reservation.panelID] as? TerminalPanel,
              panel.surface.ioMode == .manualMirror else { return nil }
        Self.bindCloudManualMirrorCallbacks(
            panel: panel,
            onResize: onResize,
            onRuntimeReady: onRuntimeReady,
            onFocus: onFocus,
            attachment: attachment
        )
        clearCloudMaterializationFailure(surfaceID: reservation.panelID)
        panel.surface.flushPendingManualSizeReportIfAttached()
        return (id, panel.id, panel.surface)
    }

    /// The request completed: the projection either adopted the reserved pane or
    /// reused another one, in which case the now-redundant reservation closes.
    func completeReservedCloudTerminalPane(_ reservation: CloudTerminalPaneReservation, adoptedPanelID: UUID) {
        guard cloudPendingCreations[reservation.panelID] === reservation else { return }
        cloudPendingCreations.removeValue(forKey: reservation.panelID)
        if let resource = SurfaceCatalog.shared.resource(forPanel: adoptedPanelID) {
            reservation.creationReceipt.finish(.success(resource))
        }
        reservation.retry = nil
        reservation.cancel = nil
        if adoptedPanelID != reservation.panelID {
            reservation.inputRelay.discard()
            SurfaceCatalog.shared.withProjectionEndReason(for: [reservation.panelID], reason: .replaced) {
                _ = closePanel(reservation.panelID, force: true)
            }
        }
    }

    /// Creation or projection failed: keep the pane where the user put it and
    /// explain inside it, with Reconnect wired to the same request's retry.
    func failReservedCloudTerminalPane(_ reservation: CloudTerminalPaneReservation, error: Error) {
        guard cloudPendingCreations[reservation.panelID] === reservation else { return }
        reservation.creationReceipt.finish(.failure(error))
        let failure = CloudPaneCreationFailure(machine: reservation.machine, error: error, context: CloudOperationContext.current)
        setCloudMaterializationFailure(
            surfaceID: reservation.panelID,
            detail: failure.errorText,
            reference: failure.copyableText
        )
    }

    /// A retry started: the pane is pending again.
    func restartReservedCloudTerminalPane(_ reservation: CloudTerminalPaneReservation) {
        guard cloudPendingCreations[reservation.panelID] === reservation else { return }
        clearCloudMaterializationFailure(surfaceID: reservation.panelID)
        // Keep the reserved tab visually stable while retrying. The pane itself
        // reports any failure through its reconnect affordance.
    }

    /// Reconnect pressed on a reserved pane's failure card replays the request.
    func retryReservedCloudTerminalPane(surfaceId: UUID) -> Bool {
        guard let reservation = cloudPendingCreations[surfaceId], let retry = reservation.retry else { return false }
        retry()
        return true
    }

    /// The pane left the workspace: end the local request. A remote terminal
    /// the machine already created stays alive, like closing any other pane.
    func cancelReservedCloudTerminalPane(panelID: UUID) {
        guard let reservation = cloudPendingCreations.removeValue(forKey: panelID) else { return }
        reservation.inputRelay.discard()
        reservation.creationReceipt.finish(.failure(CloudDiagnosticFailure.placement))
        let cancel = reservation.cancel
        reservation.cancel = nil
        reservation.retry = nil
        cancel?()
    }

    /// Drops a reservation when its remote workspace is invalidated before the
    /// provider create can begin. The pane is owned by this request, so leaving
    /// it visible would strand a loading surface after cancellation.
    func discardReservedCloudTerminalPane(_ reservation: CloudTerminalPaneReservation) {
        guard cloudPendingCreations[reservation.panelID] === reservation else { return }
        cloudPendingCreations.removeValue(forKey: reservation.panelID)
        reservation.inputRelay.discard()
        reservation.creationReceipt.finish(.failure(CloudDiagnosticFailure.placement))
        let cancel = reservation.cancel
        reservation.cancel = nil
        reservation.retry = nil
        cancel?()
        _ = closePanel(reservation.panelID, force: true)
    }

    /// Workspace teardown: every pending request ends without touching remote terminals.
    func cancelAllReservedCloudTerminalPanes() {
        for panelID in Array(cloudPendingCreations.keys) {
            cancelReservedCloudTerminalPane(panelID: panelID)
        }
    }
}
