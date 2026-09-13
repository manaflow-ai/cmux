import Foundation

/// Cloud pane presentation exists before, during and after attachment materialization.
extension Workspace {
    func cloudTerminalReconnectOverlayPresentation(forSurfaceId surfaceId: UUID) -> CloudTerminalReconnectOverlayPolicy.Presentation? {
        if let failure = cloudMaterializationFailures[surfaceId] {
            return Self.cloudMaterializationFailurePresentation(
                detail: failure.detail,
                reference: failure.reference
            )
        }
        let catalog = SurfaceCatalog.shared
        if let identity = catalog.projectionIdentity(forPanel: surfaceId, in: id),
           identity.resource.kind == .terminal, !identity.resource.machine.isLocal {
            if let provider = catalog.provider(for: identity.resource.machine) as? CmuxTuiSurfaceProvider,
               let session = provider.manualMirrorSessions[surfaceId] { return session.connectionPresentation }
            return CloudTerminalMaterializationPresentation(
                machine: catalog.machineInfo(for: identity.resource.machine), identity: identity,
                graph: catalog.cloudStates[identity.resource.machine],
                graphIsCurrent: catalog.cloudStateObservations[identity.resource.machine]?.freshness == .current
            ).presentation
        }
        return CloudTerminalReconnectOverlayPolicy.presentation(
            isManagedCloudWorkspace: isManagedCloudVMWorkspace,
            isRemoteTerminalSurface: isRemoteTerminalSurface(surfaceId) || remoteDisconnectPlaceholderPanelIds.contains(surfaceId),
            connectionState: remoteConnectionState,
            detail: remoteConnectionDetail
        )
    }

    nonisolated static func cloudMaterializationFailurePresentation(
        detail: String,
        reference: String?
    ) -> CloudTerminalReconnectOverlayPolicy.Presentation {
        var presentation = CloudTerminalReconnectOverlayPolicy.Presentation(
            title: String(localized: "cloud.overlay.materializationFailed.title", defaultValue: "Cloud terminal could not start"),
            detail: detail,
            showsProgress: false,
            showsReconnectButton: true
        )
        presentation.diagnosticReference = reference
        return presentation
    }

    func setCloudMaterializationFailure(surfaceID: UUID, detail: String, reference: String?) {
        cloudMaterializationFailures[surfaceID] = (detail: detail, reference: reference)
        postRemoteConnectionPresentationDidChange()
    }

    func clearCloudMaterializationFailure(surfaceID: UUID) {
        guard cloudMaterializationFailures.removeValue(forKey: surfaceID) != nil else { return }
        postRemoteConnectionPresentationDidChange()
    }

    /// Reconnect uses the same provider refresh for pending and materialized panes.
    func retryCloudTerminalMaterialization(surfaceID: UUID) -> Bool {
        let catalog = SurfaceCatalog.shared
        guard let identity = catalog.projectionIdentity(forPanel: surfaceID, in: id),
              identity.resource.kind == .terminal,
              let machineID = identity.resource.machine.cloudMachineID else { return false }
        clearCloudMaterializationFailure(surfaceID: surfaceID)
        Task { @MainActor in
            if let provider = await CmuxTuiSurfaceProviderRegistry.shared.providerRefreshingIfMissing(machineID: machineID) {
                await provider.refresh(force: true)
            }
        }
        return true
    }

}
