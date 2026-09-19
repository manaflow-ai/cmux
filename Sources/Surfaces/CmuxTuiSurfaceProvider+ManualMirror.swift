import CmuxTerminal
import CmuxRemoteSession
import Foundation

@MainActor
extension CmuxTuiSurfaceProvider {
    /// Creates a native manual-I/O pane and attaches it to the remote PTY.
    ///
    /// The legacy tree lookup is only an identity bridge: public `term_…`
    /// resource ids intentionally hide the numeric surface id used by the raw
    /// attach stream.
    func materializeManualMirrorTerminal(
        _ resource: SurfaceResource,
        remoteTabID: String? = nil,
        at destination: SurfaceDestination,
        focus: Bool,
        adopting reservation: CloudTerminalPaneReservation? = nil,
        restoringPanelID: UUID? = nil
    ) async throws -> CloudManualMirrorMaterialization {
        try catalog.validateOwnership(of: [resource.id], at: destination)
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else {
            throw ProviderError.machineAsleep(machineID)
        }
        let correlationID = UUID().uuidString.lowercased()
        try catalog.validateOwnership(of: [resource.id], at: destination)
        // A pool terminal opened into a mirrored workspace takes its tab there, not in
        // whichever workspace the daemon happens to focus.
        let resolved: (surfaceID: UInt64, placement: SurfaceRemotePlacement?)
        if resource.creationAttachment != nil {
            resolved = (0, nil)
        } else {
            resolved = try await resolveSurfaceIDForMaterialization(
                terminalID: resource.id.key,
                socketPath: connected.socketPath,
                commandRunner: link,
                remoteTabID: remoteTabID,
                correlationID: correlationID,
                // A newly-created terminal carries the workspace selected by the
                // creation request even before its first tab receipt arrives. Keep
                // that identity ahead of the local binding or daemon focus so a
                // missing tab_id cannot redirect projection to another workspace.
                preferredWorkspaceID: resource.remoteWorkspace?.id
                    ?? catalog.cloudPlacementCoordinator.boundRemoteWorkspaceID(
                        forLocalWorkspace: destination.workspaceID, on: machine
                    ),
                restoringPanelID: restoringPanelID
            ) { preferredWorkspaceID in
                try await self.ensureRemoteTerminalView(
                    terminalID: resource.id.key,
                    socketPath: connected.socketPath,
                    link: link,
                    preferredWorkspaceID: preferredWorkspaceID
                )
            }
        }
        let session = CloudTuiManualMirrorSession(
            machineID: machineID,
            terminalID: resource.id.key,
            remoteSurfaceID: resolved.surfaceID,
            operations: links.operations,
            creationAttachment: resource.creationAttachment,
            resolveLegacySurfaceID: { [weak self] in
                guard let self else { throw CancellationError() }
                let resolved = try await self.resolveSurfaceIDForMaterialization(
                    terminalID: resource.id.key, socketPath: connected.socketPath, commandRunner: link,
                    remoteTabID: remoteTabID, correlationID: correlationID,
                    preferredWorkspaceID: resource.remoteWorkspace?.id
                        ?? self.catalog.cloudPlacementCoordinator.boundRemoteWorkspaceID(
                            forLocalWorkspace: destination.workspaceID, on: self.machine
                        ),
                    restoringPanelID: restoringPanelID
                ) { preferredWorkspaceID in
                    try await self.ensureRemoteTerminalView(
                        terminalID: resource.id.key, socketPath: connected.socketPath,
                        link: link, preferredWorkspaceID: preferredWorkspaceID
                    )
                }
                return resolved.surfaceID
            },
            correlationID: correlationID,
            onNeedsReconnect: { [weak self] in
                self?.scheduleRefresh()
            }
        )
        let inputRouter = session.inputRouter
        do {
            try catalog.validateOwnership(of: [resource.id], at: destination)
            let created: (workspaceID: UUID, panelID: UUID, surface: TerminalSurface)
            if let reservation {
                // The user's pane already exists; bind the attachment to it. A pane
                // closed while the daemon created the terminal ends this request
                // without a replacement pane, like closing any pending pane.
                guard let workspace = Workspace.liveWorkspace(id: reservation.workspaceID),
                      let adopted = workspace.adoptReservedCloudTerminalPane(
                          reservation,
                          onResize: { [weak session] sample in session?.apply(size: sample) },
                          onRuntimeReady: { [weak session] in session?.runtimeReady() },
                          onFocus: { [weak session] in session?.claimGeometry() },
                          attachment: session.attachmentStatus
                      ) else {
                    throw CancellationError()
                }
                created = adopted
                reservation.inputRelay.attach(inputRouter)
                // The card's grace counts from the moment the pane appeared.
                session.startPresentationEpisode(elapsed: reservation.elapsed)
            } else {
                created = try SurfacePaneFactory.makeCloudManualMirrorPane(
                    at: destination,
                    focus: focus,
                    onInput: { input in inputRouter.send(input) },
                    keyNameResolver: { RemoteTmuxKeyName(inputEvent: $0)?.value },
                    onResize: { [weak session] sample in
                        session?.apply(size: sample)
                    },
                    onRuntimeReady: { [weak session] in
                        session?.runtimeReady()
                    },
                    onFocus: { [weak session] in
                        session?.claimGeometry()
                    },
                    attachment: session.attachmentStatus
                )
            }
            session.bind(surface: created.surface)
            // Preserve the workspace's existing notification-dismissal hook
            // while re-claiming geometry when this pane receives explicit
            // input. A cloud terminal can have more than one local projection;
            // the pane the user is typing in must be the authoritative owner.
            let existingExplicitInput = created.surface.onExplicitInput
            created.surface.onExplicitInput = { [weak session] in
                existingExplicitInput?()
                session?.claimGeometry()
            }
            manualMirrorSessions[created.panelID] = session
            session.reconnect(socketPath: connected.socketPath)
            return CloudManualMirrorMaterialization(
                workspaceID: created.workspaceID,
                panelID: created.panelID,
                surface: created.surface,
                session: session,
                remotePlacement: resolved.placement
            )
        } catch {
            session.stop()
            throw error
        }
    }

    /// Resolves the daemon-local surface needed by a byte attachment.
    ///
    /// A live terminal with zero remote views resolves to `noPlacement`; one
    /// unfocused remote tab is projected before resolving again. A daemon that
    /// does not answer in time is retried on the bounded materialize schedule
    /// and then reported as "did not answer", never as "not created": the
    /// terminal keeps running on the machine either way.
    /// Only restoration may repair a captured tab: an explicit user selection
    /// stays exact even if the same terminal has another live view.
    func resolveSurfaceIDForMaterialization(
        terminalID: String,
        socketPath: String,
        commandRunner: any CloudTuiCommandRunning,
        remoteTabID: String?,
        correlationID: String,
        preferredWorkspaceID: String? = nil,
        restoringPanelID: UUID? = nil,
        ensureRemoteView: @escaping @MainActor (String?) async throws -> SurfaceRemotePlacement
    ) async throws -> (surfaceID: UInt64, placement: SurfaceRemotePlacement?) {
        let resolver = CloudTerminalAttachmentResolver(machineID: machineID, commandRunner: commandRunner, socketPath: socketPath, correlationID: correlationID)
        let log = CloudTerminalAttachmentLog(correlationID: correlationID)
        var failures = 0
        var lastReason = ""
        var lastFailure = CloudTuiSurfaceIDResolution.Failure.notReady
        var projectedPlacement: SurfaceRemotePlacement?
        var targetTabID = remoteTabID
        var repairedStaleTab = false
        while true {
            try Task.checkCancellation()
            let resolution: CloudTuiSurfaceIDResolution
            if let targetTabID {
                resolution = await CloudTerminalViewResolver(commandRunner: commandRunner, socketPath: socketPath)
                    .resolve(terminalByTab: [targetTabID: terminalID])[targetTabID] ?? .retryable("no view resolution")
            } else {
                resolution = await resolver.resolve(terminalID: terminalID)
            }
            log.resolution(machineID: machineID, terminalID: terminalID, attempt: failures + 1, outcome: resolution)
            if resolution == .noPlacement, targetTabID == nil {
                let projected = try await ensureRemoteView(preferredWorkspaceID)
                projectedPlacement = projected
                targetTabID = projected.tabID
                log.projection(machineID: machineID, terminalID: terminalID, placement: projected)
                continue
            }
            // Initial and post-projection answers share the same lifecycle/error handling.
            switch resolution {
            case let .resolved(surfaceID):
                return (surfaceID, projectedPlacement)
            case .exited:
                // The remote shell already ended, including during projection.
                throw ProviderError.terminalExited(terminalID)
            case .noPlacement:
                lastReason = "the projected view did not resolve"
                lastFailure = .notReady
            case let .retryable(reason, failure):
                if resolution.isMissingTab, !repairedStaleTab, let restoringPanelID {
                    let repaired = await catalog.cloudPlacementCoordinator.repairPlacement(
                        for: SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID),
                        catalog: catalog,
                        restoringPanelID: restoringPanelID,
                        ensure: ensureRemoteView
                    )
                    if let repaired {
                        repairedStaleTab = true
                        targetTabID = repaired.tabID
                        projectedPlacement = repaired
                        log.projection(machineID: machineID, terminalID: terminalID, placement: repaired)
                        continue
                    }
                }
                lastReason = reason
                lastFailure = failure
            }
            failures += 1
            guard let delay = CloudTerminalAttachmentRetryPolicy.materialize.boundedDelay(afterFailures: failures) else {
                log.giveUp(machineID: machineID, terminalID: terminalID, attempts: failures, reason: lastReason)
                throw ProviderError.terminalAttachTimedOut(terminalID: terminalID, failure: lastFailure)
            }
            try await attachmentClock.sleep(for: delay)
        }
    }

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
            let snapshot = try await link.run(arguments: CloudTuiRequests.snapshotArguments(socketPath: socketPath))
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
    ) async -> [ObjectIdentifier: CloudTuiSurfaceIDResolution] {
        let resolver = CloudTerminalAttachmentResolver(machineID: machineID, commandRunner: link, socketPath: socketPath)
        let sessionTabs = Dictionary(uniqueKeysWithValues: manualMirrorSessions.compactMap { panelID, session in
            catalog.projection(forPanel: panelID)?.remoteTabID.map { (ObjectIdentifier(session), $0) }
        })
        let sessionsByTerminal = Dictionary(grouping: sessions.filter { sessionTabs[ObjectIdentifier($0)] == nil }, by: \.terminalID)
        var resolutions = await resolver.resolve(terminalIDs: Set(sessionsByTerminal.keys))
        let terminalsWithoutPlacement: Set<String> = Set(
            sessions.compactMap { session in
                guard resolutions[session.terminalID] == .noPlacement else { return nil }
                return session.terminalID
            }
        )
        for terminalID in terminalsWithoutPlacement {
            guard !Task.isCancelled else { break }
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
        let currentTabs = Dictionary(uniqueKeysWithValues: manualMirrorSessions.compactMap { panelID, session in
            catalog.projection(forPanel: panelID)?.remoteTabID.map { (ObjectIdentifier(session), $0) }
        })
        let terminalByTab = Dictionary(sessions.compactMap { session in
            currentTabs[ObjectIdentifier(session)].map { ($0, session.terminalID) }
        }, uniquingKeysWith: { first, _ in first })
        let views = await CloudTerminalViewResolver(commandRunner: link, socketPath: socketPath).resolve(terminalByTab: terminalByTab)
        return Dictionary(uniqueKeysWithValues: sessions.map { session in
            let id = ObjectIdentifier(session)
            let resolution = currentTabs[id].flatMap { views[$0] } ?? resolutions[session.terminalID] ?? .retryable("no resolution")
            return (id, resolution)
        })
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
        remoteTabID: String?,
        restoring: Bool = false
    ) {
        let panelID = reservation.panelID
        materializedPanels.insert(panelID)
        restoredAttachTasks[panelID]?.cancel()
        let generation = lifecycleGeneration
        reservation.retry = { [weak self] in
            guard let self else { return }
            self.restoredAttachTasks[panelID]?.cancel()
            self.attachReservedTerminalPane(reservation, resource: resource, remoteTabID: remoteTabID, restoring: restoring)
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
                    // A prior attempt may have repaired the persisted tab before
                    // attachment failed. Carry that receipt into the next round.
                    let currentTabID = restoring
                        ? self.catalog.projection(forPanel: panelID)?.remoteTabID ?? remoteTabID
                        : remoteTabID
                    let materialized = try await self.materializeManualMirrorTerminal(
                        resource,
                        remoteTabID: currentTabID,
                        at: destination,
                        focus: false,
                        adopting: reservation,
                        restoringPanelID: restoring ? reservation.panelID : nil
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
