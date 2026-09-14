import CmuxTerminal
import CmuxRemoteSession
import Foundation

@MainActor
extension CmuxTuiSurfaceProvider {
    /// Shares one in-flight remote projection among local panes opening the same pool
    /// terminal. Cancellation of an individual waiter does not cancel the shared mutation;
    /// the provider tears it down only when the machine/provider itself stops.
    private func ensureRemoteTerminalView(
        terminalID: String,
        socketPath: String,
        link: CloudMachineLink,
        preferredWorkspaceID: String? = nil
    ) async throws -> SurfaceRemotePlacement {
        // Attachment needs one backing tab per terminal, irrespective of which local
        // pane opens first. Each accepted pane then submits its bound destination via
        // the catalog's shared placement lane.
        let key = socketPath + "\u{0}" + terminalID
        if let task = remoteTerminalProjectionTasks[key] { return try await task.value }
        let task = Task<SurfaceRemotePlacement, Error> { @MainActor [weak self] in
            guard let self else { throw ProviderError.terminalNotCreated(terminalID) }
            let snapshot = try await link.run(arguments: CloudTuiCommandLine.snapshotArguments(socketPath: socketPath))
            guard let destination = await CmuxTuiSnapshotParser.terminalProjectionTarget(from: snapshot, preferringWorkspace: preferredWorkspaceID) else {
                throw ProviderError.noWorkspaceOnMachine(self.machineID)
            }
            return try await self.ensureTerminalAttachment(
                SurfaceResourceID(machine: self.machine, kind: .terminal, key: terminalID),
                preferringRemoteWorkspace: destination.target.workspaceID
            )
        }
        remoteTerminalProjectionTasks[key] = task
        defer { remoteTerminalProjectionTasks[key] = nil }
        return try await task.value
    }

    /// Refreshes attachment identities and repairs a backing placement that
    /// disappeared while a local pane stayed alive. A numeric surface id is
    /// never reused after a failed resolution; the session is first fenced,
    /// then a fresh remote projection is created and resolved once more.
    func resolveManualMirrorSessions(
        _ sessions: [CloudTuiManualMirrorSession],
        socketPath: String,
        link: CloudMachineLink
    ) async -> [String: CloudTuiSurfaceIDResolution] {
        let resolver = CloudTerminalAttachmentResolver(machineID: machineID, commandRunner: link, socketPath: socketPath)
        let sessionsByTerminal = Dictionary(grouping: sessions, by: \.terminalID)
        var resolutions = await resolver.resolve(terminalIDs: Set(sessionsByTerminal.keys))
        let terminalsWithoutPlacement: Set<String> = Set(
            sessions.compactMap { session in
                guard resolutions[session.terminalID] == .noPlacement else { return nil }
                return session.terminalID
            }
        )
        for terminalID in terminalsWithoutPlacement {
            guard !Task.isCancelled else { break }
            if pendingRemoteCreations[SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)] != nil {
                // The create receipt is ahead of the graph. Projecting now
                // could create a second backing view for the same terminal;
                // leave the session pending until the accepted snapshot retires
                // the receipt and the normal retry resolves its tab.
                resolutions[terminalID] = .retryable("awaiting the creation snapshot")
                continue
            }
            if let state = cloudState {
                let resourceID = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
                guard catalog.projections(of: resourceID).contains(where: {
                    catalog.cloudWorkspaceProjectionCoordinator.retainsProjection($0, in: state)
                }) else { continue }
            }
            for session in sessionsByTerminal[terminalID] ?? [] {
                session.markSurfaceResolutionUnavailable()
            }
            await catalog.cloudPlacementCoordinator.repairPlacement(
                for: SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID),
                catalog: catalog
            ) { preferredWorkspaceID in
                try await self.ensureRemoteTerminalView(
                    terminalID: terminalID,
                    socketPath: socketPath,
                    link: link,
                    preferredWorkspaceID: preferredWorkspaceID
                )
            }
            resolutions[terminalID] = await resolver.resolve(terminalID: terminalID)
        }
        return resolutions
    }

    /// Replaces a restored placeholder projection with a native manual pane.
    func reprojectManualMirror(
        resource: SurfaceResource,
        projection: SurfaceProjection,
        paneID: String,
        generation: UInt64
    ) async {
        guard isCurrentLifecycleGeneration(generation), isRegisteredInCatalog() else { return }
        do {
            let materialized = try await materializeManualMirrorTerminal(
                resource,
                remoteTabID: projection.remoteTabID,
                at: .tab(workspaceID: projection.workspaceID, paneID: paneID, index: nil),
                focus: false
            )
            guard isCurrentLifecycleGeneration(generation), isRegisteredInCatalog(),
                  let currentProjection = catalog.projection(forPanel: projection.panelID),
                  currentProjection.resource == resource.id,
                  currentProjection.workspaceID == projection.workspaceID else {
                SurfacePaneFactory.close(panelID: materialized.panelID, in: materialized.workspaceID)
                return
            }
            materializedPanels.insert(materialized.panelID)
            catalog.replaceProjection(
                currentProjection,
                withPanel: materialized.panelID,
                in: materialized.workspaceID,
                remotePlacement: materialized.remotePlacement
            )
            AppDelegate.shared?.workspace(containingSurfaceID: projection.panelID)?
                .clearCloudMaterializationFailure(surfaceID: projection.panelID)
            SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        } catch {
            materializedPanels.remove(projection.panelID)
            let detail = CloudMachineLink.errorText(error).isEmpty
                ? String(localized: "cloud.overlay.materializationFailed.detail", defaultValue: "The secure Cloud terminal endpoint is unavailable.")
                : CloudMachineLink.errorText(error)
            var reference: String?
            if let recorder = links.operations {
                let context = recorder.begin(.terminal)
                reference = "operation=\(context.operationID.uuidString.lowercased()) trace=\(context.traceID)"
                await recorder.finish(context, error: error)
            }
            if let workspace = AppDelegate.shared?.workspace(containingSurfaceID: projection.panelID) {
                workspace.setCloudMaterializationFailure(
                    surfaceID: projection.panelID,
                    detail: detail,
                    reference: reference
                )
            }
        }
    }
}
