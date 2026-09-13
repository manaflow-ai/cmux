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
        _ = try await links.connected(machineID: machineID)
        guard await links.link(machineID: machineID) != nil else {
            throw ProviderError.machineAsleep(machineID)
        }
        // Allocate the native pane before discovery. Resolver/snapshot/placement RPCs are
        // remote work and can take a full reconnect interval; making them a prerequisite for
        // this function leaves a blank Bonsplit slot or delays the user's split entirely. The
        // attachment owner resolves the numeric id after registration and keeps the loading
        // presentation alive until replay and a presented frame arrive.
        let preferredWorkspaceID = resource.remoteWorkspace?.id
            ?? catalog.cloudPlacementCoordinator.boundRemoteWorkspaceID(
                forLocalWorkspace: destination.workspaceID, on: machine
            )
        let initialPlacement: SurfaceRemotePlacement? = remoteTabID.flatMap { tabID in
            guard let preferredWorkspaceID else { return nil }
            return SurfaceRemotePlacement(workspaceID: preferredWorkspaceID, tabID: tabID)
        }
        let startupTrace = CloudTerminalStartupTrace(
            machineID: machineID,
            terminalID: resource.id.key
        )
        startupTrace.mark("intent", outcome: "native-pane")

        let session = CloudTuiManualMirrorSession(
            machineID: machineID,
            terminalID: resource.id.key,
            // Numeric surface ids are daemon-process local. Recovery replaces zero with an
            // authoritative id before opening the byte stream; input remains queued and is
            // re-encoded for that id when the connection is established.
            remoteSurfaceID: 0,
            operations: links.operations,
            startupTrace: startupTrace,
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
            startupTrace.mark("native-pane-allocated", surfaceID: 0)
            // A zero id is an intentional unresolved state. Starting an attach with it would
            // target an unrelated numeric surface on some old daemons. The next provider
            // refresh resolves the public id and then calls reconnect on this same session.
            scheduleRefresh()
            return CloudManualMirrorMaterialization(
                workspaceID: created.workspaceID,
                panelID: created.panelID,
                surface: created.surface,
                session: session,
                remotePlacement: initialPlacement
            )
        } catch {
            session.stop()
            throw error
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
            guard let self else { throw CancellationError() }
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
            if pendingCreationAwaitingCurrentReceipt(forTerminalID: terminalID) {
                // The create receipt is ahead of this graph. Projecting now
                // would race the daemon's own tab commit and create a second
                // backing view for one intent. Keep the native pane loading;
                // the next refresh will retry against the receipt's cursor.
                for session in sessionsByTerminal[terminalID] ?? [] {
                    session.markSurfaceResolutionUnavailable(
                        reason: .unresolved("awaiting the creation receipt")
                    )
                }
                resolutions[terminalID] = .retryable(
                    "awaiting the creation receipt",
                    failure: .notReady
                )
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
