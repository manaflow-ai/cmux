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
        let remoteSurfaceID = try await resolveSurfaceIDForMaterialization(
            terminalID: resource.id.key,
            socketPath: connected.socketPath,
            link: link
        )

        let session = CloudTuiManualMirrorSession(
            machineID: machineID,
            terminalID: resource.id.key,
            remoteSurfaceID: remoteSurfaceID,
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
                session: session
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
        link: CloudMachineLink
    ) async throws -> UInt64 {
        switch await Self.resolveModernSurfaceID(
            terminalID: terminalID,
            socketPath: socketPath,
            link: link
        ) {
        case let .resolved(surfaceID):
            return surfaceID
        case .unsupported:
            if let surfaceID = await Self.resolveSurfaceID(
                terminalID: terminalID,
                socketPath: socketPath,
                link: link
            ) {
                return surfaceID
            }
            throw ProviderError.terminalNotCreated(terminalID)
        case .failed:
            throw ProviderError.terminalNotCreated(terminalID)
        case .noPlacement:
            try await ensureRemoteTerminalView(
                terminalID: terminalID,
                socketPath: socketPath,
                link: link
            )
            if case let .resolved(surfaceID) = await Self.resolveModernSurfaceID(
                terminalID: terminalID,
                socketPath: socketPath,
                link: link
            ) {
                return surfaceID
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
        link: CloudMachineLink
    ) async throws {
        let key = socketPath + "\u{0}" + terminalID
        if let task = remoteTerminalProjectionTasks[key] {
            try await task.value
            return
        }
        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else {
                throw ProviderError.terminalNotCreated(terminalID)
            }
            try await self.createRemoteTerminalView(
                terminalID: terminalID,
                socketPath: socketPath,
                link: link
            )
        }
        remoteTerminalProjectionTasks[key] = task
        defer { remoteTerminalProjectionTasks[key] = nil }
        try await task.value
    }

    /// Adds one daemon-side tab view for a zero-view terminal. The destination is read from a
    /// fresh public snapshot immediately before the mutation, so a cached sidebar tree cannot
    /// send the terminal to a pane that was closed or moved in the meantime.
    private func createRemoteTerminalView(
        terminalID: String,
        socketPath: String,
        link: CloudMachineLink
    ) async throws {
        // Reuse one idempotency key across the bounded revision retry. If the
        // daemon applied the mutation but the CLI lost its response, a retry
        // replays the original result instead of creating another tab.
        let idempotencyKey = "cmux-cloud-projection-\(UUID().uuidString.lowercased())"
        var revisionRetry = false
        while true {
            try Task.checkCancellation()
            // The first resolver result may have raced another opener. Re-check the
            // authoritative mapping before mutating topology so two local projections do
            // not create duplicate daemon tabs for the same zero-view terminal.
            switch await Self.resolveModernSurfaceID(
                terminalID: terminalID,
                socketPath: socketPath,
                link: link
            ) {
            case .resolved:
                return
            case .failed, .unsupported:
                // This helper is reached only after a modern resolver reported no placement;
                // a generation change or malformed response is fail-closed.
                throw ProviderError.terminalNotCreated(terminalID)
            case .noPlacement:
                break
            }
            let snapshotData = try await link.run(
                arguments: CloudTuiCommandLine.snapshotArguments(socketPath: socketPath)
            )
            try Task.checkCancellation()
            guard let projection = await CmuxTuiSnapshotParser.terminalProjectionTarget(from: snapshotData)
            else {
                throw ProviderError.terminalNotCreated(terminalID)
            }
            let arguments = CloudTuiCommandLine.projectTerminalArguments(
                socketPath: socketPath,
                terminalID: terminalID,
                target: projection.target,
                expectedRevision: projection.revision,
                idempotencyKey: idempotencyKey
            )
            try Task.checkCancellation()
            do {
                _ = try await link.run(arguments: arguments)
                return
            } catch {
                guard !revisionRetry,
                      projection.revision != nil,
                      Self.isRevisionConflict(error) else {
                    throw error
                }
                revisionRetry = true
            }
        }
    }

    nonisolated private static func isRevisionConflict(_ error: Error) -> Bool {
        let text = CloudMachineLink.errorText(error).lowercased()
        return text.contains("revision conflict")
            || text.contains("revision_conflict")
            || text.contains("stale revision")
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
            do {
                try await ensureRemoteTerminalView(
                    terminalID: terminalID,
                    socketPath: socketPath,
                    link: link
                )
                resolutions[terminalID] = await Self.resolveModernSurfaceID(
                    terminalID: terminalID,
                    socketPath: socketPath,
                    link: link
                )
            } catch {
                resolutions[terminalID] = .failed
            }
        }
        return resolutions
    }

    /// Replaces a restored placeholder projection with a native manual pane.
    func reprojectManualMirror(
        resource: SurfaceResource,
        projection: SurfaceProjection,
        paneID: String
    ) async {
        do {
            let materialized = try await materializeManualMirrorTerminal(
                resource,
                at: .tab(workspaceID: projection.workspaceID, paneID: paneID, index: nil),
                focus: false
            )
            materializedPanels.insert(materialized.panelID)
            catalog.endProjections(panelID: projection.panelID)
            catalog.record(SurfaceProjection(
                resource: resource.id,
                workspaceID: materialized.workspaceID,
                panelID: materialized.panelID
            ))
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
        case .noPlacement, .failed:
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
