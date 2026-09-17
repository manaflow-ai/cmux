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

    /// Attaches a reserved pane to `resource` and keeps trying until it works.
    ///
    /// Used for restored panes and for a Cloud workspace opened as a whole: the
    /// projection is already recorded on the reserved pane, so the layout is
    /// complete before any machine round trip, and every pane attaches in
    /// parallel. A failure is transient by default (the link is still coming up
    /// after a relaunch, the daemon's ordered lane is busy): the loop waits on
    /// the background backoff and tries again, and only after several rounds
    /// does the pane show Reconnect, which restarts the loop at once. Closing
    /// the pane cancels the loop; a terminal that exited is reported as such.
    func attachReservedTerminalPane(
        _ reservation: CloudTerminalPaneReservation,
        resource: SurfaceResource,
        remoteTabID: String?
    ) {
        let panelID = reservation.panelID
        materializedPanels.insert(panelID)
        restoredAttachTasks[panelID]?.cancel()
        let generation = lifecycleGeneration
        reservation.retry = { [weak self] in
            guard let self else { return }
            self.restoredAttachTasks[panelID]?.cancel()
            self.attachReservedTerminalPane(reservation, resource: resource, remoteTabID: remoteTabID)
        }
        reservation.cancel = { [weak self] in
            guard let self else { return }
            self.restoredAttachTasks.removeValue(forKey: panelID)?.cancel()
            self.materializedPanels.remove(panelID)
        }
        restoredAttachTasks[panelID] = Task { @MainActor [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.isCurrentLifecycleGeneration(generation), self.isRegisteredInCatalog(),
                      let workspace = Workspace.liveWorkspace(id: reservation.workspaceID),
                      workspace.cloudPendingCreations[panelID] === reservation else { return }
                let destination = SurfaceDestination.tab(
                    workspaceID: reservation.workspaceID,
                    paneID: SurfacePaneFactory.paneID(ofPanel: panelID, in: reservation.workspaceID) ?? "",
                    index: nil
                )
                do {
                    let materialized = try await self.materializeManualMirrorTerminal(
                        resource,
                        remoteTabID: remoteTabID,
                        at: destination,
                        focus: false,
                        adopting: reservation
                    )
                    guard !Task.isCancelled, self.isCurrentLifecycleGeneration(generation) else {
                        self.manualMirrorSessions.removeValue(forKey: materialized.panelID)?.stop()
                        return
                    }
                    if let placement = materialized.remotePlacement {
                        self.catalog.cloudPlacementCoordinator.confirmPlacement(placement, on: self.machine)
                        if let current = self.catalog.projection(forPanel: panelID) {
                            self.catalog.setRemotePlacement(for: current, placement: placement)
                        }
                    }
                    workspace.completeReservedCloudTerminalPane(reservation, adoptedPanelID: materialized.panelID)
                    self.restoredAttachTasks[panelID] = nil
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    if let providerError = error as? CmuxTuiSurfaceProvider.ProviderError,
                       case .terminalExited = providerError {
                        // The shell ended while the pane was waiting: the pane
                        // closes the way an exited local terminal does.
                        self.restoredAttachTasks[panelID] = nil
                        workspace.cancelReservedCloudTerminalPane(panelID: panelID)
                        SurfacePaneFactory.closeExited(panelID: panelID, in: reservation.workspaceID)
                        return
                    }
                    failures += 1
                    self.attachmentLog.giveUp(
                        machineID: self.machineID, terminalID: resource.id.key,
                        attempts: failures, reason: CloudMachineLink.errorText(error)
                    )
                    if failures >= Self.reservedAttachFailuresBeforeReporting {
                        workspace.failReservedCloudTerminalPane(reservation, error: error)
                    }
                    let delay = CloudTerminalAttachmentRetryPolicy.background.cappedDelay(afterFailures: failures)
                    do { try await self.attachmentClock.sleep(for: delay) } catch { return }
                }
            }
        }
    }

    /// Rounds of the background backoff (1 s, 2 s, 4 s, 8 s: about fifteen
    /// seconds) a restored pane may fail before it explains itself with Reconnect.
    static let reservedAttachFailuresBeforeReporting = 4
}
