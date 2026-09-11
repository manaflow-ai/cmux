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
            preferredWorkspaceID: catalog.cloudPlacementCoordinator.boundRemoteWorkspaceID(
                forLocalWorkspace: destination.workspaceID, on: machine
            )
        )

        let session = CloudTuiManualMirrorSession(
            machineID: machineID,
            terminalID: resource.id.key,
            remoteSurfaceID: resolved.surfaceID,
            initiallyClaimsGeometry: focus,
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
                }
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

    /// Resolves the daemon-local surface needed by a byte attachment. A live terminal with
    /// zero remote views intentionally resolves to `surface:null`; create one unfocused remote
    /// tab in the daemon's focused pane before resolving again. The operation is retried once
    /// after the projection to cover the commit-to-snapshot handoff without ever selecting a
    /// stale numeric id.
    private func resolveSurfaceIDForMaterialization(
        terminalID: String,
        socketPath: String,
        link: CloudMachineLink,
        preferredWorkspaceID: String? = nil
    ) async throws -> (surfaceID: UInt64, placement: SurfaceRemotePlacement?) {
        switch await Self.resolveModernSurfaceID(
            terminalID: terminalID,
            socketPath: socketPath,
            link: link
        ) {
        case let .resolved(surfaceID):
            return (surfaceID, nil)
        case .unsupported:
            if let surfaceID = await Self.resolveSurfaceID(
                terminalID: terminalID,
                socketPath: socketPath,
                link: link
            ) {
                return (surfaceID, nil)
            }
            throw ProviderError.terminalNotCreated(terminalID)
        case .failed:
            throw ProviderError.terminalNotCreated(terminalID)
        case .exited:
            // The remote shell already ended. Opening a pane for it would show
            // a frozen screen that never reconnects.
            throw ProviderError.terminalNotCreated(terminalID)
        case .noPlacement:
            let placement = try await ensureRemoteTerminalView(
                terminalID: terminalID,
                socketPath: socketPath,
                link: link,
                preferredWorkspaceID: preferredWorkspaceID
            )
            if case let .resolved(surfaceID) = await Self.resolveModernSurfaceID(
                terminalID: terminalID,
                socketPath: socketPath,
                link: link
            ) {
                return (surfaceID, placement)
            }
            throw ProviderError.terminalNotCreated(terminalID)
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
    ) async -> [String: CloudTuiSurfaceIDResolution] {
        var resolutions = await Self.resolveSurfaceIDs(
            terminalIDs: Set(sessions.map(\.terminalID)),
            socketPath: socketPath,
            link: link
        )
        let terminalsWithoutPlacement: Set<String> = Set(
            sessions.compactMap { session in
                guard resolutions[session.terminalID] == .noPlacement else { return nil }
                return session.terminalID
            }
        )
        for terminalID in terminalsWithoutPlacement {
            guard !Task.isCancelled else { break }
            for session in sessions where session.terminalID == terminalID {
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
            resolutions[terminalID] = await Self.resolveModernSurfaceID(
                terminalID: terminalID, socketPath: socketPath, link: link
            )
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
            SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        } catch {
            materializedPanels.remove(projection.panelID)
        }
    }

    /// Resolves one terminal for materialization, using the legacy tree only
    /// when the daemon explicitly reports that the private resolver is not
    /// supported. Other failures fail closed to prevent stale-id routing.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated static func resolveSurfaceID(
        terminalID: String,
        socketPath: String,
        link: CloudMachineLink
    ) async -> UInt64? {
        switch await resolveModernSurfaceID(
            terminalID: terminalID,
            socketPath: socketPath,
            link: link
        ) {
        case let .resolved(surfaceID):
            return surfaceID
        case .unsupported:
            let parser = CloudTuiLegacySnapshotParser()
            guard let tree = try? await link.run(
                arguments: CloudTuiCommandLine.legacyListWorkspacesArguments(socketPath: socketPath)
            ) else { return nil }
            return parser.surfaceID(from: tree, terminalID: terminalID)
        case .noPlacement, .exited, .failed:
            return nil
        }
    }

    /// Resolves the private command without touching MainActor state or
    /// performing a compatibility-tree traversal.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated static func resolveModernSurfaceID(
        terminalID: String,
        socketPath: String,
        link: CloudMachineLink
    ) async -> CloudTuiSurfaceIDResolution {
        guard let arguments = CloudTuiCommandLine.resolveTerminalArguments(
            socketPath: socketPath,
            terminalID: terminalID
        ) else { return .failed }
        let parser = CloudTuiLegacySnapshotParser()
        do {
            let resolved = try await link.run(arguments: arguments)
            switch parser.resolvedSurface(from: resolved) {
            case let .surface(surfaceID):
                return .resolved(surfaceID)
            case .noPlacement:
                return .noPlacement
            case .exited:
                return .exited
            case .malformed:
                return .failed
            }
        } catch {
            if isExplicitUnsupportedResolverError(error) {
                return .unsupported
            }
            // A pre-protocol-9 daemon has no generation-aware resolver. Probe
            // the authoritative identify response before allowing the legacy
            // tree fallback; all other failures remain fail-closed.
            guard let identifyArguments = CloudTuiCommandLine.identifyArguments(socketPath: socketPath),
                  let identify = try? await link.run(arguments: identifyArguments),
                  let protocolVersion = parser.protocolVersion(from: identify) else {
                return .failed
            }
            return protocolVersion < 9 ? .unsupported : .failed
        }
    }

    /// Resolves a set of terminal IDs with one modern request per ID and at
    /// most one legacy tree fallback. The compatibility parser performs one
    /// O(N) traversal for all unresolved IDs.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated static func resolveSurfaceIDs(
        terminalIDs: Set<String>,
        socketPath: String,
        link: CloudMachineLink
    ) async -> [String: CloudTuiSurfaceIDResolution] {
        guard !terminalIDs.isEmpty else { return [:] }
        var results: [String: CloudTuiSurfaceIDResolution] = [:]
        var legacyIDs: Set<String> = []
        for terminalID in terminalIDs {
            let result = await resolveModernSurfaceID(
                terminalID: terminalID,
                socketPath: socketPath,
                link: link
            )
            results[terminalID] = result
            if result == .unsupported {
                legacyIDs.insert(terminalID)
            }
        }
        if !legacyIDs.isEmpty,
           let tree = try? await link.run(
               arguments: CloudTuiCommandLine.legacyListWorkspacesArguments(socketPath: socketPath)
           ) {
            let parser = CloudTuiLegacySnapshotParser()
            let legacy = parser.surfaceIDs(from: tree, terminalIDs: legacyIDs)
            for terminalID in legacyIDs {
                results[terminalID] = legacy[terminalID].map(CloudTuiSurfaceIDResolution.resolved)
                    ?? .failed
            }
        }
        return results
    }

    /// Whether the daemon's answer means "this resolver cannot serve me",
    /// which sends the caller to the compatibility tree instead of failing
    /// closed.
    ///
    /// Two answers qualify. `operation.unsupported` is a daemon that predates
    /// the resolver. `invalid_terminal_id` is an id-space mismatch:
    /// `resolve-terminal` takes a *terminal host* id (UUIDv4 hex, per
    /// spec/sdk-schema.json), while everything the app holds is a public
    /// `term_…` resource id whose hex is not a UUIDv4 and which no command maps
    /// to a host id. So the modern resolver can never answer for the ids this
    /// app has, and treating that as a hard failure made every cloud terminal
    /// fail with "cmux-tui did not report the new terminal". The compatibility
    /// tree does carry the mapping (`terminal_resource_id` beside `surface`),
    /// so the fallback is the path that actually resolves.
    nonisolated static func isExplicitUnsupportedResolverError(_ error: Error) -> Bool {
        guard case let CloudMachineLink.LinkError.exited(_, output) = error else { return false }
        let lines = output.split(whereSeparator: \.isNewline)
        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if object["code"] as? String == "operation.unsupported"
                || object["error_code"] as? String == "operation.unsupported" {
                return true
            }
            let detailError = (object["details"] as? [String: Any])?["error"] as? String
            if object["message"] as? String == "invalid_terminal_id"
                || detailError == "invalid_terminal_id" {
                return true
            }
        }
        return false
    }
}
