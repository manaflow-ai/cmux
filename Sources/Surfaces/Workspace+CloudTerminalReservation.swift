import CmuxRemoteSession
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
    /// Inserts the pane a Cloud terminal will occupy before the machine has created it.
    /// Returns nil when the destination no longer exists.
    func reserveCloudTerminalPane(
        machine: SurfaceMachineID,
        at destination: SurfaceDestination,
        focus: Bool
    ) -> CloudTerminalPaneReservation? {
        guard !isRetiredFromOwningTabManager,
              surfaceOwnershipPolicy.rejection(for: machine) == nil else { return nil }
        let relay = CloudOptimisticInputRelay()
        guard let panel = makeRemoteTmuxPanePanel(
            onInput: { input in relay.send(input) },
            keyNameResolver: { RemoteTmuxKeyName(inputEvent: $0)?.value }
        ) else { return nil }
        panel.surface.setManualIONoReflow(false)
        let panelID: UUID
        do {
            // Creation is asynchronous, but the pane is already usable as a
            // terminal surface. Keep the tab strip quiet while the remote
            // attachment resolves; failures are rendered in the pane itself.
            panelID = try insertCloudManualMirrorPanel(panel, at: destination, focus: focus, isLoading: false)
        } catch {
            #if DEBUG
            cmuxDebugLog("cloud.pane.reserveFailed machine=\(machine.rawValue) error=\(String(reflecting: error))")
            #endif
            return nil
        }
        let reservation = CloudTerminalPaneReservation(workspaceID: id, panelID: panelID, machine: machine, inputRelay: relay)
        cloudPendingCreations[panelID] = reservation
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
        // The tab-strip spinner clears on real attachment, not on adoption.
        let panelID = reservation.panelID
        attachment.onStateChange = { [weak self, weak attachment] state in
            guard state == .attached || state == .ended else { return }
            attachment?.onStateChange = nil
            self?.setCloudManualMirrorTabLoading(panelID: panelID, false)
        }
        if attachment.state == .attached { attachment.onStateChange?(.attached) }
        panel.surface.flushPendingManualSizeReportIfAttached()
        return (id, panel.id, panel.surface)
    }

    /// The request completed: the projection either adopted the reserved pane or
    /// reused another one, in which case the now-redundant reservation closes.
    func completeReservedCloudTerminalPane(_ reservation: CloudTerminalPaneReservation, adoptedPanelID: UUID) {
        guard cloudPendingCreations[reservation.panelID] === reservation else { return }
        cloudPendingCreations.removeValue(forKey: reservation.panelID)
        reservation.resolveResource = nil
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
        setCloudManualMirrorTabLoading(panelID: reservation.panelID, false)
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
        setCloudManualMirrorTabLoading(panelID: reservation.panelID, true)
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
        let cancel = reservation.cancel
        reservation.cancel = nil
        reservation.resolveResource = nil
        reservation.retry = nil
        cancel?()
    }

    /// Workspace teardown: every pending request ends without touching remote terminals.
    func cancelAllReservedCloudTerminalPanes() {
        for panelID in Array(cloudPendingCreations.keys) {
            cancelReservedCloudTerminalPane(panelID: panelID)
        }
    }
}
