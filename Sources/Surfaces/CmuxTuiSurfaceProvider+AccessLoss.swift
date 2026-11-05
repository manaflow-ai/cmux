import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    /// Cards every restored terminal of this machine that is not attached yet:
    /// those waiting for the machine, and those whose attach is in flight.
    func showRestoredTerminalsUnavailable(detail: String, retry: (@MainActor () -> Void)?) {
        for panelID in restoredAttachTasks.keys {
            guard let workspaceID = catalog.projection(forPanel: panelID)?.workspaceID else { continue }
            Workspace.liveWorkspace(id: workspaceID)?.failRestoredCloudTerminalPane(
                panelID: panelID,
                detail: detail,
                retry: retry
            )
        }
        catalog.showRestoredMachineUnavailable(machine, detail: detail, retry: retry)
    }

    /// The control plane answered that this user can no longer reach the
    /// machine. Automatic reconnects stop, and every attached pane shows the
    /// access-lost card; the pane itself stays open so the user decides.
    func noteAccessLost(_ loss: CloudMachineAccessLoss = .forbidden) {
        guard accessLoss == nil else { return }
        accessLoss = loss
        let stopReason = CloudTuiManualMirrorStopReason(accessLoss: loss)
        // A pane still restoring keeps its reservation; rebuilding it on
        // regain restarts its attach.
        accessLostPanelIDs.formUnion(restoredAttachTasks.keys)
        // A restored terminal that has not attached yet has no session to stop.
        showRestoredTerminalsUnavailable(detail: stopReason.endedPresentation?.detail ?? "") {
            Task { @MainActor in _ = await CmuxTuiSurfaceProviderRegistry.shared.refresh(force: true) }
        }
        for task in restoredAttachTasks.values { task.cancel() }
        restoredAttachTasks.removeAll()
        attachmentRetry.cancel()
        for session in manualMirrorSessions.values { session.stop(reason: stopReason) }
        accessLostPanelIDs.formUnion(manualMirrorSessions.keys)
        manualMirrorSessions.removeAll()
        manualMirrorSurfaceIDsSocketPath = nil
        let detail = stopReason.endedPresentation?.detail ?? ""
        // Cloud browser and display panes of this machine keep the same state,
        // in the browser's own unavailable card.
        for task in browserPaneTasks.values { task.cancel() }
        browserPaneTasks.removeAll()
        for projection in catalog.projections where projection.resource.machine == machine {
            AppDelegate.shared?.browserPanel(for: projection.panelID)?.cloudAccess.showUnavailable(detail)
        }
        guard isRegisteredInCatalog() else { return }
        publishLinkStatus(.error, error: detail)
    }
    /// An authorized read listed the machine for its owning team, so a
    /// machine-scoped loss was wrong or is over. Refreshes resume, and the
    /// panes the loss ended are rebuilt by the next refresh's reprojection.
    /// A revoked sign-in stays: listing machines does not need the Mac's
    /// network enrollment, so it cannot prove that the sign-in works again.
    ///
    /// An owner mismatch stays too: the machine can still be listed while the
    /// credential this Mac holds for it names another owner, so clearing it
    /// on every listing would only cycle the card.
    func noteAccessConfirmed() {
        guard let accessLoss, accessLoss == .forbidden || accessLoss == .notFound else { return }
        self.accessLoss = nil
        materializedPanels.subtract(accessLostPanelIDs)
        accessLostPanelIDs.removeAll()
        catalog.clearRestoredMachineUnavailable(machine)
        guard isRegisteredInCatalog() else { return }
        publishLinkStatus(.connecting, error: nil)
        // Browser and display panes showed the unavailable card; routing them
        // again replaces it.
        refreshCloudBrowserRoutes()
    }
}
