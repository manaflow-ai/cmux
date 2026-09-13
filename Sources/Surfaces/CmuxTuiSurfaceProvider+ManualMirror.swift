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
        focus: Bool
    ) async throws -> CloudManualMirrorMaterialization {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else {
            throw ProviderError.machineAsleep(machineID)
        }
        // A pool terminal opened into a mirrored workspace takes its tab there, not in
        // whichever workspace the daemon happens to focus.
        let resolved = try await resolveSurfaceIDForMaterialization(
            terminalID: resource.id.key,
            socketPath: connected.socketPath,
            link: link,
            remoteTabID: remoteTabID,
            // A newly-created terminal carries the workspace selected by the
            // creation request even before its first tab receipt arrives. Keep
            // that identity ahead of the local binding or daemon focus so a
            // missing tab_id cannot redirect projection to another workspace.
            preferredWorkspaceID: resource.remoteWorkspace?.id
                ?? catalog.cloudPlacementCoordinator.boundRemoteWorkspaceID(
                    forLocalWorkspace: destination.workspaceID, on: machine
                )
        )

        let session = CloudTuiManualMirrorSession(
            machineID: machineID,
            terminalID: resource.id.key,
            remoteSurfaceID: resolved.surfaceID,
            operations: links.operations,
            onNeedsReconnect: { [weak self] in
                self?.scheduleRefresh()
            }
        )
        let inputRouter = session.inputRouter
        do {
            let created = try SurfacePaneFactory.makeCloudManualMirrorPane(
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
    private func resolveSurfaceIDForMaterialization(
        terminalID: String,
        socketPath: String,
        link: CloudMachineLink,
        remoteTabID: String?,
        preferredWorkspaceID: String? = nil
    ) async throws -> (surfaceID: UInt64, placement: SurfaceRemotePlacement?) {
        let resolver = CloudTerminalAttachmentResolver(machineID: machineID, commandRunner: link, socketPath: socketPath)
        var failures = 0
        var lastReason = ""
        var lastFailure = CloudTuiSurfaceIDResolution.Failure.notReady
        var projectedPlacement: SurfaceRemotePlacement?
        while true {
            try Task.checkCancellation()
            var resolution: CloudTuiSurfaceIDResolution
            if let remoteTabID {
                resolution = await CloudTerminalViewResolver(commandRunner: link, socketPath: socketPath)
                    .resolve(terminalByTab: [remoteTabID: terminalID])[remoteTabID] ?? .retryable("no view resolution")
            } else { resolution = await resolver.resolve(terminalID: terminalID) }
            attachmentLog.resolution(machineID: machineID, terminalID: terminalID, attempt: failures + 1, outcome: resolution)
            if resolution == .noPlacement, remoteTabID == nil, projectedPlacement == nil {
                let projected = try await ensureRemoteTerminalView(
                    terminalID: terminalID,
                    socketPath: socketPath,
                    link: link,
                    preferredWorkspaceID: preferredWorkspaceID
                )
                projectedPlacement = projected
                attachmentLog.projection(machineID: machineID, terminalID: terminalID, placement: projected)
                resolution = await resolver.resolve(terminalID: terminalID)
                attachmentLog.resolution(machineID: machineID, terminalID: terminalID, attempt: failures + 1, outcome: resolution)
            }
            // Initial and post-projection answers share the same lifecycle/error handling.
            switch resolution {
            case let .resolved(surfaceID):
                return (surfaceID, projectedPlacement)
            case .exited:
                // The remote shell already ended, including during projection.
                throw ProviderError.terminalExited(terminalID)
            case .noPlacement:
                lastReason = "the requested view is not ready to attach"
                lastFailure = .notReady
            case let .retryable(reason, failure):
                lastReason = reason
                lastFailure = failure
            }
            failures += 1
            guard let delay = CloudTerminalAttachmentRetryPolicy.materialize.boundedDelay(afterFailures: failures) else {
                attachmentLog.giveUp(machineID: machineID, terminalID: terminalID, attempts: failures, reason: lastReason)
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
        let terminalByTab = Dictionary(sessions.compactMap { session in
            sessionTabs[ObjectIdentifier(session)].map { ($0, session.terminalID) }
        }, uniquingKeysWith: { first, _ in first })
        let views = await CloudTerminalViewResolver(commandRunner: link, socketPath: socketPath).resolve(terminalByTab: terminalByTab)
        return Dictionary(uniqueKeysWithValues: sessions.map { session in
            let id = ObjectIdentifier(session)
            let resolution = sessionTabs[id].flatMap { views[$0] } ?? resolutions[session.terminalID] ?? .retryable("no resolution")
            return (id, resolution)
        })
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
