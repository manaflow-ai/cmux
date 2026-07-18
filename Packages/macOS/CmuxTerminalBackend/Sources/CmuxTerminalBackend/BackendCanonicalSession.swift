internal import Foundation

/// One fail-closed connection to the daemon-owned topology and terminal authority.
///
/// The session installs one atomic snapshot, resumes at that exact revision, and
/// publishes only contiguous deltas. A gap, authority change, overflow, or malformed
/// event closes the connection so the UI cannot combine stale state with new commands.
public actor BackendCanonicalSession {
    private static let subscriberEventCapacity = 256
    private let client: BackendProtocolClient
    private let transport: any BackendPeerIdentityTransport
    private let expectation: BackendCanonicalSessionExpectation
    private let handshakePolicy: BackendHandshakePolicy
    private var projection = TopologyProjection<CanonicalTopology>()
    private var eventTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<BackendCanonicalSessionEvent>.Continuation] = [:]
    private var connected = false
    private var terminalError: BackendCanonicalSessionError?

    /// Creates a session over one credential-bearing transport.
    public init(
        transport: any BackendPeerIdentityTransport,
        expectation: BackendCanonicalSessionExpectation,
        handshakePolicy: BackendHandshakePolicy = .terminalAuthorityV1,
        eventCapacity: Int = BackendProtocolClient.defaultEventCapacity
    ) {
        self.transport = transport
        client = BackendProtocolClient(transport: transport, eventCapacity: eventCapacity)
        self.expectation = expectation
        self.handshakePolicy = handshakePolicy
    }

    /// Returns a newest-state stream, seeded immediately when already connected.
    public func events() -> AsyncStream<BackendCanonicalSessionEvent> {
        let identifier = UUID()
        let pair = AsyncStream<BackendCanonicalSessionEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.subscriberEventCapacity)
        )
        continuations[identifier] = pair.continuation
        if let snapshot = currentSnapshot() {
            pair.continuation.yield(.snapshot(snapshot))
        } else if let terminalError {
            pair.continuation.yield(.disconnected(terminalError))
        }
        pair.continuation.onTermination = { @Sendable _ in
            Task { await self.removeContinuation(identifier) }
        }
        return pair.stream
    }

    /// Connects, validates identity, installs a snapshot, and resumes from its revision.
    @discardableResult
    public func connect() async throws -> TopologySnapshot {
        guard !connected, eventTask == nil else {
            throw BackendCanonicalSessionError.alreadyConnected
        }
        terminalError = nil
        do {
            try await client.connect()
            let actualPeerIdentity = try await transport.peerIdentity()
            if let expectedPeerIdentity = expectation.peerIdentity,
               actualPeerIdentity != expectedPeerIdentity {
                throw BackendCanonicalSessionError.unexpectedPeerIdentity(
                    expected: expectedPeerIdentity,
                    actual: actualPeerIdentity
                )
            }
            let identify = try await client.identify()
            try handshakePolicy.validate(identify)
            try validateIdentity(identify)

            let snapshot = try await client.topologySnapshot()
            guard snapshot.authority == identify.authority else {
                throw BackendCanonicalSessionError.snapshotAuthorityMismatch(
                    expected: identify.authority,
                    actual: snapshot.authority
                )
            }
            projection.install(snapshot: snapshot)

            let stream = await client.events()
            let subscription = try await client.subscribeTopology(
                authority: snapshot.authority,
                revision: snapshot.revision
            )
            switch subscription {
            case .resnapshotRequired(let required):
                throw BackendCanonicalSessionError.resnapshotRequired(required.reason)
            case .subscribed(let accepted):
                guard accepted.authority == snapshot.authority else {
                    throw BackendCanonicalSessionError.subscriptionAuthorityMismatch(
                        expected: snapshot.authority,
                        actual: accepted.authority
                    )
                }
                guard accepted.fromRevision == snapshot.revision else {
                    throw BackendCanonicalSessionError.subscriptionCursorMismatch(
                        expected: snapshot.revision,
                        actual: accepted.fromRevision
                    )
                }
            }

            connected = true
            publish(.snapshot(snapshot))
            eventTask = Task { [weak self] in
                do {
                    for try await event in stream {
                        await self?.receive(event)
                    }
                    await self?.finish(
                        BackendCanonicalSessionError.topologyStreamFailed("connection closed")
                    )
                } catch is CancellationError {
                    // Explicit close owns the terminal state transition.
                } catch {
                    await self?.finish(
                        BackendCanonicalSessionError.topologyStreamFailed(String(describing: error))
                    )
                }
            }
            return snapshot
        } catch {
            projection.invalidate()
            await client.close()
            if let sessionError = error as? BackendCanonicalSessionError {
                terminalError = sessionError
                publish(.disconnected(sessionError))
            }
            throw error
        }
    }

    /// The latest topology paired atomically with its authority and revision.
    public func currentSnapshot() -> TopologySnapshot? {
        guard let authority = projection.authority,
              let revision = projection.revision,
              let topology = projection.value
        else { return nil }
        return TopologySnapshot(authority: authority, revision: revision, topology: topology)
    }

    /// Returns the canonical surface matching one daemon-local handle.
    public func surface(handle: UInt64) -> CanonicalSurface? {
        projection.value?.surface(handle: handle)
    }

    /// Closes only this frontend connection. Backend-owned PTYs remain alive.
    public func close() async {
        eventTask?.cancel()
        eventTask = nil
        connected = false
        projection.invalidate()
        terminalError = nil
        await client.close()
        finishContinuations()
    }

    /// Creates the first terminal in a new backend workspace.
    public func newWorkspace(
        name: String? = nil,
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        try requireConnected()
        return try await client.newWorkspace(name: name, columns: columns, rows: rows)
    }

    /// Idempotently creates or reattaches one stable caller-identified terminal.
    public func ensureTerminal(
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        workingDirectory: String? = nil,
        command: String? = nil,
        arguments: [String]? = nil,
        environment: [String: String] = [:],
        initialInput: String? = nil,
        waitAfterCommand: Bool = false,
        columns: UInt16,
        rows: UInt16
    ) async throws -> BackendEnsuredTerminalPlacement {
        try requireConnected()
        return try await client.ensureTerminal(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            workingDirectory: workingDirectory,
            command: command,
            arguments: arguments,
            environment: environment,
            initialInput: initialInput,
            waitAfterCommand: waitAfterCommand,
            columns: columns,
            rows: rows
        )
    }

    /// Moves one stable terminal into a workspace without replacing its PTY.
    public func reparentTerminal(
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID
    ) async throws -> BackendReparentedTerminalPlacement {
        try requireConnected()
        return try await client.reparentTerminal(
            surfaceID: surfaceID,
            workspaceID: workspaceID
        )
    }

    public func configureRendererPresentation(
        id: PresentationID,
        expectedGeneration: UInt64,
        configuration: BackendRendererPresentationConfiguration
    ) async throws -> BackendRendererPresentationReceipt {
        try requireConnected()
        return try await client.configureRendererPresentation(
            id: id,
            expectedGeneration: expectedGeneration,
            configuration: configuration
        )
    }

    public func detachRendererPresentation(
        id: PresentationID,
        expectedGeneration: UInt64
    ) async throws {
        try requireConnected()
        try await client.detachRendererPresentation(
            id: id,
            expectedGeneration: expectedGeneration
        )
    }

    public func setTerminalPreedit(
        presentationID: PresentationID,
        rendererGeneration: UInt64,
        text: String?
    ) async throws {
        try requireConnected()
        try await client.setTerminalPreedit(
            presentationID: presentationID,
            rendererGeneration: rendererGeneration,
            text: text
        )
    }

    public func releaseRendererFrame(
        _ release: BackendRendererFrameRelease
    ) async throws -> BackendRendererFrameReleaseResponse {
        try requireConnected()
        return try await client.releaseRendererFrame(release)
    }

    public func rendererWorkers() async throws -> BackendRendererWorkersResponse {
        try requireConnected()
        return try await client.rendererWorkers()
    }

    /// Creates a terminal tab in one backend pane.
    public func newTerminalTab(
        pane: UInt64? = nil,
        workingDirectory: String? = nil,
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) async throws -> BackendSurfacePlacement {
        try requireConnected()
        return try await client.newTerminalTab(
            pane: pane,
            workingDirectory: workingDirectory,
            columns: columns,
            rows: rows
        )
    }

    /// Registers a frontend presentation against stable canonical identities.
    public func openPresentation(
        view: BackendPresentationView,
        zoom: BackendPresentationZoom = BackendPresentationZoom(),
        scroll: BackendPresentationScroll = BackendPresentationScroll()
    ) async throws -> BackendPresentation {
        try requireConnected()
        return try await client.openPresentation(view: view, zoom: zoom, scroll: scroll)
    }

    /// Removes one connection-owned presentation without closing its PTY.
    public func closePresentation(id: PresentationID) async throws {
        try requireConnected()
        try await client.closePresentation(id: id)
    }

    public func sendTerminalKey(
        surface: UInt64,
        event: BackendTerminalKeyEvent
    ) async throws -> BackendTerminalKeyResponse {
        try requireConnected()
        return try await client.sendTerminalKey(surface: surface, event: event)
    }

    public func sendTerminalNamedKey(surface: UInt64, key: String) async throws {
        try requireConnected()
        try await client.sendTerminalNamedKey(surface: surface, key: key)
    }

    public func sendTerminalMouse(
        surface: UInt64,
        event: BackendTerminalMouseEvent
    ) async throws -> BackendTerminalMouseResponse {
        try requireConnected()
        return try await client.sendTerminalMouse(surface: surface, event: event)
    }

    public func sendTerminalText(surface: UInt64, text: String, paste: Bool = false) async throws {
        try requireConnected()
        try await client.sendTerminalText(surface: surface, text: text, paste: paste)
    }

    public func resizeTerminal(
        surface: UInt64,
        columns: UInt16,
        rows: UInt16
    ) async throws -> BackendSurfaceResizeResponse {
        try requireConnected()
        return try await client.resizeTerminal(surface: surface, columns: columns, rows: rows)
    }

    public func scrollTerminal(surface: UInt64, rowDelta: Int64) async throws {
        try requireConnected()
        try await client.scrollTerminal(surface: surface, rowDelta: rowDelta)
    }

    public func terminalState(surfaceID: SurfaceID) async throws -> BackendTerminalStateResponse {
        try requireConnected()
        return try await client.terminalState(surfaceID: surfaceID)
    }

    public func performTerminalBindingAction(
        surfaceID: SurfaceID,
        action: String,
        repeatCount: UInt32? = nil
    ) async throws -> BackendTerminalActionResponse {
        try requireConnected()
        return try await client.performTerminalBindingAction(
            surfaceID: surfaceID,
            action: action,
            repeatCount: repeatCount
        )
    }

    public func terminalSelection(
        surfaceID: SurfaceID,
        operation: BackendTerminalSelectionOperation
    ) async throws -> BackendTerminalSelectionResponse {
        try requireConnected()
        return try await client.terminalSelection(surfaceID: surfaceID, operation: operation)
    }

    public func terminalCopyMode(
        surfaceID: SurfaceID,
        operation: BackendTerminalCopyModeOperation,
        adjustment: BackendTerminalCopyModeAdjustment? = nil,
        count: UInt32? = nil
    ) async throws -> BackendTerminalActionResponse {
        try requireConnected()
        return try await client.terminalCopyMode(
            surfaceID: surfaceID,
            operation: operation,
            adjustment: adjustment,
            count: count
        )
    }

    public func terminalSearch(
        surfaceID: SurfaceID,
        operation: BackendTerminalSearchOperation,
        query: String? = nil
    ) async throws -> BackendTerminalActionResponse {
        try requireConnected()
        return try await client.terminalSearch(
            surfaceID: surfaceID,
            operation: operation,
            query: query
        )
    }

    public func terminalScroll(
        surfaceID: SurfaceID,
        operation: BackendTerminalScrollOperation,
        amount: Int64? = nil
    ) async throws -> BackendTerminalActionResponse {
        try requireConnected()
        return try await client.terminalScroll(
            surfaceID: surfaceID,
            operation: operation,
            amount: amount
        )
    }

    public func readTerminalScreen(surface: UInt64) async throws -> BackendScreenText {
        try requireConnected()
        return try await client.readTerminalScreen(surface: surface)
    }

    public func terminalProcessInfo(surface: UInt64) async throws -> BackendProcessInfo {
        try requireConnected()
        return try await client.terminalProcessInfo(surface: surface)
    }

    public func closeTerminal(surface: UInt64) async throws {
        try requireConnected()
        try await client.closeTerminal(surface: surface)
    }

    private func validateIdentity(_ identify: BackendIdentifyResponse) throws {
        guard identify.session == expectation.session else {
            throw BackendCanonicalSessionError.unexpectedSession(
                expected: expectation.session,
                actual: identify.session
            )
        }
        if let authority = expectation.authority, identify.authority != authority {
            throw BackendCanonicalSessionError.unexpectedAuthority(
                expected: authority,
                actual: identify.authority
            )
        }
        if let processID = expectation.processID, identify.processID != processID {
            throw BackendCanonicalSessionError.unexpectedProcessID(
                expected: processID,
                actual: identify.processID
            )
        }
    }

    private func receive(_ event: BackendServerEvent) async {
        guard connected else { return }
        if event.name == "renderer-worker-changed" {
            do {
                publish(.rendererWorkerChanged(try event.rendererWorkerChanged()))
            } catch {
                await finish(.topologyStreamFailed(String(describing: error)))
            }
            return
        }
        if event.name == "renderer-presentation-ready" {
            do {
                publish(.rendererPresentationReady(try event.rendererPresentationReady()))
            } catch {
                await finish(.topologyStreamFailed(String(describing: error)))
            }
            return
        }
        guard event.name == "topology-delta" || event.name == "topology-resnapshot-required" else {
            return
        }
        do {
            switch try event.topologyStreamEvent() {
            case .delta(let delta):
                try projection.apply(delta)
                publish(.delta(delta))
            case .resnapshotRequired(let required):
                try projection.requireResnapshot(required)
            }
        } catch let error as BackendCanonicalSessionError {
            await finish(error)
        } catch let error as TopologyProjectionError {
            await finish(.topologyStreamFailed(String(describing: error)))
        } catch {
            await finish(.topologyStreamFailed(String(describing: error)))
        }
    }

    private func requireConnected() throws {
        guard connected else { throw BackendCanonicalSessionError.notConnected }
    }

    private func finish(_ error: BackendCanonicalSessionError) async {
        guard connected || terminalError == nil else { return }
        connected = false
        projection.invalidate()
        terminalError = error
        publish(.disconnected(error))
        await client.close()
    }

    private func publish(_ event: BackendCanonicalSessionEvent) {
        var retired: [UUID] = []
        for (identifier, continuation) in continuations {
            switch continuation.yield(event) {
            case .enqueued:
                break
            case .dropped, .terminated:
                continuation.finish()
                retired.append(identifier)
            @unknown default:
                continuation.finish()
                retired.append(identifier)
            }
        }
        for identifier in retired {
            continuations.removeValue(forKey: identifier)
        }
    }

    private func finishContinuations() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}

private extension CanonicalTopology {
    func surface(handle: UInt64) -> CanonicalSurface? {
        for workspace in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    if let surface = pane.tabs.first(where: { $0.id == handle }) {
                        return surface
                    }
                }
            }
        }
        return nil
    }
}
