import CmuxTerminal
import CmuxTerminalBackend
import CmuxTerminalBackendService
import CmuxTerminalRenderProtocol
import Darwin
import Foundation

/// Process-wide owner of trusted backend connection replacement and terminal commands.
actor TerminalBackendClientCoordinator: TerminalBackendClient {
    typealias ReadinessProvider = @Sendable () async throws -> BackendServiceBootstrapResult
    typealias SessionFactory = @Sendable (BackendServiceReadiness) -> any TerminalBackendSessionServing

    private let readinessProvider: ReadinessProvider
    private let sessionFactory: SessionFactory
    private let reconnectPolicy: TerminalBackendReconnectPolicy
    private let screenTextLimiter = TerminalBackendScreenTextLimiter()

    private struct RendererPresentationRecord: Sendable {
        let binding: TerminalBackendTerminalBinding
        let backendID: PresentationID
        var canonicalGeneration: UInt64
        var descriptor: TerminalBackendPresentationDescriptor
        var receipt: BackendRendererPresentationReceipt?
        var ready: BackendRendererPresentationReady?
    }

    private var connected: TerminalBackendConnectedSession?
    private var latestSnapshot: TopologySnapshot?
    private var connectionTask: Task<TerminalBackendConnectedSession, any Error>?
    private var connectionAttemptID = UUID()
    private var eventTask: Task<Void, Never>?
    private var rendererPresentations: [UUID: RendererPresentationRecord] = [:]
    private var rendererContinuations: [
        UUID: AsyncStream<TerminalBackendRendererEvent>.Continuation
    ] = [:]
    private var snapshotContinuations: [UUID: AsyncStream<TopologySnapshot>.Continuation] = [:]

    init(
        bootstrapCoordinator: BackendServiceBootstrapCoordinator,
        runtimePaths: BackendServiceRuntimePaths,
        reconnectPolicy: TerminalBackendReconnectPolicy = .appStartup
    ) {
        readinessProvider = {
            try await bootstrapCoordinator.ensureRegistered()
        }
        sessionFactory = { readiness in
            BackendCanonicalSession(
                transport: UnixBackendTransport(path: runtimePaths.socketURL.path),
                expectation: BackendCanonicalSessionExpectation(
                    session: readiness.session,
                    authority: readiness.authority,
                    processID: readiness.processID,
                    peerIdentity: readiness.peerIdentity
                )
            )
        }
        self.reconnectPolicy = reconnectPolicy
    }

    init(
        readinessProvider: @escaping ReadinessProvider,
        sessionFactory: @escaping SessionFactory,
        reconnectPolicy: TerminalBackendReconnectPolicy = .immediate
    ) {
        self.readinessProvider = readinessProvider
        self.sessionFactory = sessionFactory
        self.reconnectPolicy = reconnectPolicy
    }

    deinit {
        connectionTask?.cancel()
        eventTask?.cancel()
    }

    func start() async {
        _ = try? await connectedSession()
    }

    func rendererEvents() -> AsyncStream<TerminalBackendRendererEvent> {
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            rendererContinuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeRendererContinuation(identifier) }
            }
        }
    }

    func canonicalSnapshots() async throws -> AsyncStream<TopologySnapshot> {
        _ = try await connectedSession()
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            snapshotContinuations[identifier] = continuation
            if let latestSnapshot {
                continuation.yield(latestSnapshot)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotContinuation(identifier) }
            }
        }
    }

    func disconnectFrontend() async {
        connectionAttemptID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        eventTask?.cancel()
        eventTask = nil
        rendererPresentations.removeAll()
        latestSnapshot = nil
        let previous = connected
        connected = nil
        await previous?.session.close()
    }

    func ensureTerminal(
        _ request: TerminalBackendTerminalRequest
    ) async throws -> TerminalBackendTerminalBinding {
        let connection = try await connectedSession()
        let placement = try await connection.session.ensureTerminal(
            workspaceID: WorkspaceID(rawValue: request.appWorkspaceID),
            surfaceID: SurfaceID(rawValue: request.appSurfaceID),
            workingDirectory: request.workingDirectory,
            command: request.command,
            arguments: request.arguments,
            environment: request.environment,
            initialInput: request.initialInput,
            waitAfterCommand: request.waitAfterCommand,
            columns: request.columns,
            rows: request.rows
        )
        guard placement.workspaceID.rawValue == request.appWorkspaceID,
              placement.surfaceID.rawValue == request.appSurfaceID else {
            await invalidate(connection)
            throw BackendProtocolError.peerIdentityMismatch
        }
        return TerminalBackendTerminalBinding(
            authority: connection.readiness.authority,
            appWorkspaceID: request.appWorkspaceID,
            appSurfaceID: request.appSurfaceID,
            workspaceHandle: placement.workspace,
            workspaceID: placement.workspaceID,
            surfaceHandle: placement.surface,
            surfaceID: placement.surfaceID,
            columns: request.columns,
            rows: request.rows,
            created: placement.created
        )
    }

    func apply(
        _ mutation: TerminalExternalRuntimeMutation,
        to binding: TerminalBackendTerminalBinding,
        presentation: TerminalBackendPresentationDescriptor?
    ) async throws -> TerminalBackendMutationOutcome {
        let connection = try await connectedSession(for: binding)
        var outcome = TerminalBackendMutationOutcome()
        switch mutation {
        case .input(.text(let input)):
            try await connection.session.sendTerminalText(
                surface: binding.surfaceHandle,
                text: input.text,
                paste: input.kind == .paste
            )
        case .input(.key(let key)):
            _ = try await connection.session.sendTerminalKey(
                surface: binding.surfaceHandle,
                event: BackendTerminalKeyEvent(
                    key: key.key,
                    modifiers: key.modifiers.rawValue,
                    consumedModifiers: key.consumedModifiers.rawValue,
                    text: key.text ?? "",
                    unshiftedCodepoint: key.unshiftedCodepoint,
                    action: key.action.backendAction
                )
            )
        case .input(.namedKey(let key)):
            try await connection.session.sendTerminalNamedKey(
                surface: binding.surfaceHandle,
                key: key
            )
        case .mouse(let mouse):
            guard let presentation,
                  let record = rendererPresentations[presentation.presentationID],
                  let receipt = record.receipt,
                  let geometry = rendererGeometry(record) else {
                throw TerminalBackendClientError.rendererNotReady
            }
            _ = try await connection.session.sendTerminalMouse(
                surface: binding.surfaceHandle,
                event: BackendTerminalMouseEvent(
                    action: mouse.action.backendAction,
                    button: mouse.button?.backendButton,
                    modifiers: mouse.modifiers.rawValue,
                    x: mouse.xPixels,
                    y: mouse.yPixels,
                    viewportWidth: receipt.width,
                    viewportHeight: receipt.height,
                    cellWidth: geometry.cellWidth,
                    cellHeight: geometry.cellHeight,
                    padding: geometry.padding,
                    anyButtonPressed: mouse.anyButtonPressed,
                    clickCount: mouse.clickCount
                )
            )
            if mouse.action == .release {
                outcome.install(
                    try await connection.session.terminalState(surfaceID: binding.surfaceID).state
                )
            }
        case .preedit(let text):
            guard let presentation else {
                throw TerminalBackendClientError.presentationUnavailable
            }
            if let receipt = rendererPresentations[presentation.presentationID]?.receipt {
                try await connection.session.setTerminalPreedit(
                    presentationID: receipt.presentationID,
                    rendererGeneration: receipt.rendererGeneration,
                    text: text
                )
            }
        case .focus:
            if let presentation,
               rendererPresentations[presentation.presentationID] != nil,
               presentation.visible {
                outcome.rendererAttachment = try await configureRenderer(
                    presentation,
                    binding: binding,
                    connection: connection
                )
            }
            outcome.processMetadata = try await processMetadata(
                for: binding,
                connection: connection
            )
        case .visibility(let visible):
            guard let presentation else {
                throw TerminalBackendClientError.presentationUnavailable
            }
            if visible {
                outcome.rendererAttachment = try await configureRenderer(
                    presentation,
                    binding: binding,
                    connection: connection
                )
            } else {
                await removeRendererPresentation(
                    presentationID: presentation.presentationID,
                    connection: connection
                )
            }
            outcome.processMetadata = try await processMetadata(
                for: binding,
                connection: connection
            )
        case .resize(let viewport):
            if let presentation, presentation.visible {
                outcome.rendererAttachment = try await configureRenderer(
                    presentation,
                    binding: binding,
                    connection: connection
                )
            } else if let columns = viewport.proposedColumns.flatMap(UInt16.init(exactly:)),
                      let rows = viewport.proposedRows.flatMap(UInt16.init(exactly:)) {
                _ = try await connection.session.resizeTerminal(
                    surface: binding.surfaceHandle,
                    columns: columns,
                    rows: rows
                )
            }
        case .bindingAction(let action, let repeatCount):
            let response = try await connection.session.performTerminalBindingAction(
                surfaceID: binding.surfaceID,
                action: action,
                repeatCount: repeatCount
            )
            outcome.install(response)
        case .selection(let operation):
            let response = try await connection.session.terminalSelection(
                surfaceID: binding.surfaceID,
                operation: operation.backendOperation
            )
            outcome.install(response.state)
            outcome.selection = response.selection?.externalSelection
            outcome.selectionWasRead = true
        case .copyMode(let operation, let adjustment, let count):
            let response = try await connection.session.terminalCopyMode(
                surfaceID: binding.surfaceID,
                operation: operation.backendOperation,
                adjustment: adjustment?.backendAdjustment,
                count: count
            )
            outcome.install(response)
        case .search(let operation, let query):
            let response = try await connection.session.terminalSearch(
                surfaceID: binding.surfaceID,
                operation: operation.backendOperation,
                query: query
            )
            outcome.install(response)
        case .scroll(let operation, let amount):
            let response = try await connection.session.terminalScroll(
                surfaceID: binding.surfaceID,
                operation: operation.backendOperation,
                amount: amount
            )
            outcome.install(response)
        case .reparent(let workspaceID):
            if let presentation {
                await removeRendererPresentation(
                    presentationID: presentation.presentationID,
                    connection: connection
                )
            }
            let placement = try await connection.session.reparentTerminal(
                surfaceID: binding.surfaceID,
                workspaceID: WorkspaceID(rawValue: workspaceID)
            )
            guard placement.workspaceID.rawValue == workspaceID,
                  placement.surfaceID == binding.surfaceID,
                  placement.surface == binding.surfaceHandle else {
                await invalidate(connection)
                throw BackendProtocolError.peerIdentityMismatch
            }
            let updatedBinding = TerminalBackendTerminalBinding(
                authority: binding.authority,
                appWorkspaceID: workspaceID,
                appSurfaceID: binding.appSurfaceID,
                workspaceHandle: placement.workspace,
                workspaceID: placement.workspaceID,
                surfaceHandle: placement.surface,
                surfaceID: placement.surfaceID,
                columns: binding.columns,
                rows: binding.rows,
                created: false
            )
            outcome.binding = updatedBinding
            if let presentation, presentation.visible {
                outcome.rendererAttachment = try await configureRenderer(
                    presentation,
                    binding: updatedBinding,
                    connection: connection
                )
            }
        case .closeCanonicalTerminal:
            let presentationIDs = rendererPresentations.compactMap { identifier, record in
                record.binding.appSurfaceID == binding.appSurfaceID ? identifier : nil
            }
            for presentationID in presentationIDs {
                await removeRendererPresentation(
                    presentationID: presentationID,
                    connection: connection
                )
            }
            try await connection.session.closeTerminal(surface: binding.surfaceHandle)
            outcome.lifecycle = .processExited
        }
        return outcome
    }

    func readScreenText(
        _ request: TerminalExternalScreenTextRequest,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> String? {
        let connection = try await connectedSession(for: binding)
        let text = try await connection.session.readTerminalScreen(
            surface: binding.surfaceHandle
        ).text
        switch request {
        case .visible:
            return text
        case .vtTail(let maximumRows, let maximumBytes):
            return screenTextLimiter.tail(
                text,
                maximumRows: maximumRows,
                maximumBytes: maximumBytes
            )
        }
    }

    func readSelection(
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalExternalSelection? {
        let connection = try await connectedSession(for: binding)
        return try await connection.session.terminalSelection(
            surfaceID: binding.surfaceID,
            operation: .read
        ).selection?.externalSelection
    }

    func readTerminalUXState(
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalBackendMutationOutcome {
        let connection = try await connectedSession(for: binding)
        var outcome = TerminalBackendMutationOutcome()
        outcome.install(
            try await connection.session.terminalState(surfaceID: binding.surfaceID).state
        )
        return outcome
    }

    func detachPresentation(
        presentationID: UUID,
        from binding: TerminalBackendTerminalBinding?
    ) async {
        guard let record = rendererPresentations[presentationID] else { return }
        if let binding, binding.appSurfaceID != record.binding.appSurfaceID { return }
        guard let connection = try? await connectedSession(for: record.binding) else {
            rendererPresentations.removeValue(forKey: presentationID)
            return
        }
        await removeRendererPresentation(
            presentationID: presentationID,
            connection: connection
        )
    }

    func releaseFrame(_ release: TerminalRenderFrameRelease) async {
        guard let connection = try? await connectedSession(),
              connection.readiness.authority.daemonInstanceID.rawValue
                == release.metadata.daemonInstanceID else { return }
        _ = try? await connection.session.releaseRendererFrame(
            BackendRendererFrameRelease(
                daemonInstanceID: DaemonInstanceID(
                    rawValue: release.metadata.daemonInstanceID
                ),
                rendererEpoch: release.metadata.rendererEpoch,
                terminalID: SurfaceID(rawValue: release.metadata.terminalID),
                terminalEpoch: release.metadata.terminalEpoch,
                terminalSequence: release.metadata.terminalSequence,
                presentationID: PresentationID(
                    rawValue: release.metadata.presentationID
                ),
                presentationGeneration: release.metadata.presentationGeneration,
                frameSequence: release.metadata.frameSequence,
                surfaceID: release.surfaceID
            )
        )
    }

    private func configureRenderer(
        _ descriptor: TerminalBackendPresentationDescriptor,
        binding: TerminalBackendTerminalBinding,
        connection: TerminalBackendConnectedSession
    ) async throws -> TerminalBackendRendererAttachment? {
        guard descriptor.visible,
              descriptor.viewport.widthPixels > 0,
              descriptor.viewport.heightPixels > 0,
              let width = UInt32(exactly: descriptor.viewport.widthPixels),
              let height = UInt32(exactly: descriptor.viewport.heightPixels) else {
            throw TerminalBackendClientError.presentationUnavailable
        }

        var record: RendererPresentationRecord
        let openedNewPresentation: Bool
        if let existing = rendererPresentations[descriptor.presentationID] {
            guard existing.binding.appSurfaceID == binding.appSurfaceID else {
                throw TerminalBackendClientError.presentationUnavailable
            }
            record = existing
            openedNewPresentation = false
        } else {
            let opened = try await connection.session.openPresentation(
                view: BackendPresentationView(
                    workspaceID: binding.workspaceID,
                    surfaceID: binding.surfaceID
                ),
                zoom: BackendPresentationZoom(),
                scroll: BackendPresentationScroll(surfaceID: binding.surfaceID)
            )
            record = RendererPresentationRecord(
                binding: binding,
                backendID: opened.id,
                canonicalGeneration: opened.generation,
                descriptor: descriptor,
                receipt: nil,
                ready: nil
            )
            openedNewPresentation = true
        }

        let columns = descriptor.viewport.proposedColumns.flatMap(UInt16.init(exactly:))
            ?? record.ready?.columns
            ?? record.receipt?.metrics?.columns
            ?? record.receipt?.columns
            ?? binding.columns
        let rows = descriptor.viewport.proposedRows.flatMap(UInt16.init(exactly:))
            ?? record.ready?.rows
            ?? record.receipt?.metrics?.rows
            ?? record.receipt?.rows
            ?? binding.rows
        let receipt: BackendRendererPresentationReceipt
        do {
            receipt = try await connection.session.configureRendererPresentation(
                id: record.backendID,
                expectedGeneration: record.canonicalGeneration,
                configuration: BackendRendererPresentationConfiguration(
                    width: width,
                    height: height,
                    backingScaleFactor: descriptor.viewport.xScale,
                    columns: columns,
                    rows: rows,
                    pixelFormat: descriptor.pixelFormat.backendPixelFormat,
                    colorSpace: descriptor.colorSpace.backendColorSpace,
                    frameEndpointService: descriptor.endpoint.serviceName,
                    frameEndpointCapability: descriptor.endpoint.capability,
                    resolvedConfigRevision: descriptor.resolvedConfigRevision,
                    resolvedConfig: descriptor.resolvedConfig,
                    focused: descriptor.focused,
                    cursorBlinkVisible: descriptor.focused && descriptor.visible,
                    preedit: descriptor.preedit
                )
            )
        } catch {
            if openedNewPresentation {
                try? await connection.session.closePresentation(id: record.backendID)
            }
            throw error
        }
        record.canonicalGeneration = receipt.canonicalGeneration
        record.descriptor = descriptor
        record.receipt = receipt
        record.ready = nil
        rendererPresentations[descriptor.presentationID] = record
        return try rendererAttachment(record)
    }

    private func removeRendererPresentation(
        presentationID: UUID,
        connection: TerminalBackendConnectedSession
    ) async {
        guard let record = rendererPresentations.removeValue(forKey: presentationID) else {
            return
        }
        if record.receipt != nil {
            try? await connection.session.detachRendererPresentation(
                id: record.backendID,
                expectedGeneration: record.canonicalGeneration
            )
        }
        try? await connection.session.closePresentation(id: record.backendID)
    }

    private func rendererAttachment(
        _ record: RendererPresentationRecord
    ) throws -> TerminalBackendRendererAttachment? {
        guard let receipt = record.receipt else { return nil }
        let processID: UInt32
        let effectiveUserID: UInt32
        let metrics: (
            columns: UInt16,
            rows: UInt16,
            cellWidth: UInt32,
            cellHeight: UInt32,
            padding: BackendRendererPadding
        )
        if let ready = record.ready {
            processID = ready.workerProcessID
            effectiveUserID = ready.workerEffectiveUserID
            metrics = (
                ready.columns,
                ready.rows,
                ready.cellWidth,
                ready.cellHeight,
                ready.padding
            )
        } else if let receiptMetrics = receipt.metrics,
                  let receiptProcessID = receipt.workerProcessID,
                  let receiptEffectiveUserID = receipt.workerEffectiveUserID {
            processID = receiptProcessID
            effectiveUserID = receiptEffectiveUserID
            metrics = (
                receiptMetrics.columns,
                receiptMetrics.rows,
                receiptMetrics.cellWidth,
                receiptMetrics.cellHeight,
                receiptMetrics.padding
            )
        } else {
            return nil
        }
        guard let signedProcessID = Int32(exactly: processID) else {
            throw TerminalBackendClientError.rendererNotReady
        }
        let worker = try TerminalRenderWorkerIdentity(
            processID: signedProcessID,
            effectiveUserID: effectiveUserID
        )
        let fence = try TerminalRenderPresentationFence(
            daemonInstanceID: receipt.daemonInstanceID.rawValue,
            rendererEpoch: receipt.rendererEpoch,
            terminalID: receipt.terminalID.rawValue,
            terminalEpoch: receipt.terminalEpoch,
            minimumTerminalSequence: max(
                receipt.minimumContentSequence,
                record.ready?.canonicalSequence ?? 0
            ),
            presentationID: receipt.presentationID.rawValue,
            presentationGeneration: receipt.rendererGeneration,
            width: receipt.width,
            height: receipt.height,
            pixelFormat: receipt.pixelFormat.terminalPixelFormat,
            colorSpace: receipt.colorSpace.terminalColorSpace,
            completionRequirement: .producerCompleted
        )
        return TerminalBackendRendererAttachment(
            fence: fence,
            worker: worker,
            cellMetrics: TerminalExternalCellMetrics(
                columns: Int(metrics.columns),
                rows: Int(metrics.rows),
                cellWidthPixels: Int(metrics.cellWidth),
                cellHeightPixels: Int(metrics.cellHeight),
                surfaceWidthPixels: Int(receipt.width),
                surfaceHeightPixels: Int(receipt.height),
                backingScale: receipt.backingScaleFactor
            )
        )
    }

    private func rendererGeometry(
        _ record: RendererPresentationRecord
    ) -> (cellWidth: UInt32, cellHeight: UInt32, padding: BackendRendererPadding)? {
        if let ready = record.ready {
            return (ready.cellWidth, ready.cellHeight, ready.padding)
        }
        guard let metrics = record.receipt?.metrics else { return nil }
        return (metrics.cellWidth, metrics.cellHeight, metrics.padding)
    }

    private func processMetadata(
        for binding: TerminalBackendTerminalBinding,
        connection: TerminalBackendConnectedSession
    ) async throws -> TerminalExternalProcessMetadata {
        let process = try await connection.session.terminalProcessInfo(
            surface: binding.surfaceHandle
        )
        return TerminalExternalProcessMetadata(
            foregroundProcessID: process.processID.map(Int.init),
            controllingTTYName: process.controllingTTYName
        )
    }

    private func connectedSession(
        for binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalBackendConnectedSession {
        let connection = try await connectedSession()
        guard connection.readiness.authority == binding.authority else {
            throw TerminalBackendClientError.authorityChanged(
                expected: binding.authority,
                actual: connection.readiness.authority
            )
        }
        return connection
    }

    private func connectedSession() async throws -> TerminalBackendConnectedSession {
        if let connected { return connected }
        if let connectionTask { return try await connectionTask.value }

        let attemptID = UUID()
        connectionAttemptID = attemptID
        let readinessProvider = readinessProvider
        let sessionFactory = sessionFactory
        let reconnectPolicy = reconnectPolicy
        let task = Task {
            try await Self.connect(
                readinessProvider: readinessProvider,
                sessionFactory: sessionFactory,
                reconnectPolicy: reconnectPolicy
            )
        }
        connectionTask = task
        do {
            let result = try await task.value
            guard connectionAttemptID == attemptID else {
                await result.session.close()
                throw CancellationError()
            }
            connectionTask = nil
            connected = result
            latestSnapshot = result.snapshot
            publishSnapshot(result.snapshot)
            observe(result, attemptID: attemptID)
            if let workers = try? await result.session.rendererWorkers(),
               connected?.readiness == result.readiness {
                publishRenderer(.reconnected(workers))
            }
            guard connected?.readiness == result.readiness else {
                return try await connectedSession()
            }
            return result
        } catch {
            if connectionAttemptID == attemptID {
                connectionTask = nil
            }
            throw error
        }
    }

    private func observe(
        _ connection: TerminalBackendConnectedSession,
        attemptID: UUID
    ) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            let events = await connection.session.events()
            for await event in events {
                guard let self else { return }
                switch event {
                case .snapshot(let snapshot):
                    await self.receivedSnapshot(snapshot, from: connection)
                case .delta(let delta):
                    await self.receivedDelta(delta, from: connection)
                case .rendererWorkerChanged(let changed):
                    await self.receivedWorkerChanged(changed, from: connection)
                case .rendererPresentationReady(let ready):
                    await self.receivedPresentationReady(ready, from: connection)
                case .disconnected:
                    await self.connectionDidEnd(connection, attemptID: attemptID)
                    return
                }
            }
            await self?.connectionDidEnd(connection, attemptID: attemptID)
        }
    }

    private func receivedSnapshot(
        _ snapshot: TopologySnapshot,
        from connection: TerminalBackendConnectedSession
    ) {
        guard connected?.readiness == connection.readiness else { return }
        latestSnapshot = snapshot
        publishSnapshot(snapshot)
    }

    private func receivedDelta(
        _ delta: TopologyDelta,
        from connection: TerminalBackendConnectedSession
    ) {
        guard connected?.readiness == connection.readiness else { return }
        let snapshot = TopologySnapshot(
            authority: delta.authority,
            revision: delta.revision,
            topology: delta.replacement
        )
        latestSnapshot = snapshot
        publishSnapshot(snapshot)
    }

    private func receivedPresentationReady(
        _ ready: BackendRendererPresentationReady,
        from connection: TerminalBackendConnectedSession
    ) {
        guard connected?.readiness == connection.readiness else { return }
        guard let entry = rendererPresentations.first(where: { _, record in
            guard let receipt = record.receipt else { return false }
            return receipt.presentationID == ready.presentationID
                && receipt.workspaceID == ready.workspaceID
                && receipt.rendererEpoch == ready.rendererEpoch
                && receipt.terminalID == ready.terminalID
                && receipt.terminalEpoch == ready.terminalEpoch
                && receipt.rendererGeneration == ready.presentationGeneration
        }) else { return }
        var record = entry.value
        record.ready = ready
        rendererPresentations[entry.key] = record
        guard let attachment = try? rendererAttachment(record) else { return }
        publishRenderer(
            .presentationReady(
                presentationID: entry.key,
                attachment: attachment
            )
        )
    }

    private func receivedWorkerChanged(
        _ changed: BackendRendererWorkerChanged,
        from connection: TerminalBackendConnectedSession
    ) {
        guard connected?.readiness == connection.readiness else { return }
        for (identifier, var record) in rendererPresentations
            where record.binding.workspaceID == changed.workspaceID {
            record.receipt = nil
            record.ready = nil
            rendererPresentations[identifier] = record
        }
        publishRenderer(.workerChanged(changed))
    }

    private func connectionDidEnd(
        _ connection: TerminalBackendConnectedSession,
        attemptID: UUID
    ) async {
        guard connectionAttemptID == attemptID,
              connected?.readiness == connection.readiness else { return }
        connected = nil
        latestSnapshot = nil
        rendererPresentations.removeAll()
        publishRenderer(.connectionLost(connection.readiness.authority))
        eventTask = nil
        connectionAttemptID = UUID()
        // Reconnection is finite and uses an intended cancellable backoff.
        _ = try? await connectedSession()
    }

    private func invalidate(_ connection: TerminalBackendConnectedSession) async {
        guard connected?.readiness == connection.readiness else { return }
        connected = nil
        latestSnapshot = nil
        rendererPresentations.removeAll()
        publishRenderer(.connectionLost(connection.readiness.authority))
        eventTask?.cancel()
        eventTask = nil
        connectionAttemptID = UUID()
        await connection.session.close()
    }

    private func publishRenderer(_ event: TerminalBackendRendererEvent) {
        var overflowed: [UUID] = []
        for (identifier, continuation) in rendererContinuations {
            if case .dropped = continuation.yield(event) {
                continuation.finish()
                overflowed.append(identifier)
            }
        }
        for identifier in overflowed {
            rendererContinuations.removeValue(forKey: identifier)
        }
    }

    private func publishSnapshot(_ snapshot: TopologySnapshot) {
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeRendererContinuation(_ identifier: UUID) {
        rendererContinuations.removeValue(forKey: identifier)
    }

    private func removeSnapshotContinuation(_ identifier: UUID) {
        snapshotContinuations.removeValue(forKey: identifier)
    }

    private static func connect(
        readinessProvider: ReadinessProvider,
        sessionFactory: SessionFactory,
        reconnectPolicy: TerminalBackendReconnectPolicy
    ) async throws -> TerminalBackendConnectedSession {
        var nextDelayIndex = 0
        while true {
            do {
                let readiness = try await resolveReadiness(readinessProvider)
                let session = sessionFactory(readiness)
                do {
                    let snapshot = try await session.connect()
                    guard snapshot.authority == readiness.authority,
                          snapshot.revision >= readiness.topologyRevision else {
                        await session.close()
                        throw BackendProtocolError.peerIdentityMismatch
                    }
                    return TerminalBackendConnectedSession(
                        readiness: readiness,
                        session: session,
                        snapshot: snapshot
                    )
                } catch {
                    await session.close()
                    throw error
                }
            } catch {
                guard shouldRetry(error),
                      nextDelayIndex < reconnectPolicy.delays.count else {
                    if error is TerminalBackendClientError { throw error }
                    throw TerminalBackendClientError.reconnectExhausted(
                        String(describing: error)
                    )
                }
                let delay = reconnectPolicy.delays[nextDelayIndex]
                nextDelayIndex += 1
                if delay > .zero {
                    // This is the retry policy's bounded, cancellable backoff.
                    try await ContinuousClock().sleep(for: delay)
                }
            }
        }
    }

    private static func resolveReadiness(
        _ readinessProvider: ReadinessProvider
    ) async throws -> BackendServiceReadiness {
        switch try await readinessProvider() {
        case .ready(let readiness):
            return readiness
        case .disabled:
            throw TerminalBackendClientError.disabled
        case .requiresApproval:
            throw TerminalBackendClientError.requiresApproval
        case .missingBundleItem(let item):
            throw TerminalBackendClientError.missingBundleItem(item)
        case .serviceNotFound:
            throw TerminalBackendClientError.serviceNotFound
        case .backendUnavailable:
            throw TerminalBackendClientError.unavailable
        }
    }

    private static func shouldRetry(_ error: any Error) -> Bool {
        if error as? TerminalBackendClientError == .unavailable { return true }
        if let protocolError = error as? BackendProtocolError {
            switch protocolError {
            case .connectionClosed, .notConnected:
                return true
            default:
                return false
            }
        }
        let cocoaError = error as NSError
        guard cocoaError.domain == NSPOSIXErrorDomain else { return false }
        switch Int32(cocoaError.code) {
        case ENOENT, ECONNREFUSED, ECONNRESET, EPIPE, ENOTCONN, ESHUTDOWN:
            return true
        default:
            return false
        }
    }
}

private extension TerminalExternalKeyAction {
    var backendAction: BackendTerminalKeyAction {
        switch self {
        case .press: .press
        case .release: .release
        case .repeat: .repeat
        }
    }
}

private extension TerminalExternalMouseAction {
    var backendAction: BackendTerminalMouseAction {
        switch self {
        case .press: .press
        case .release: .release
        case .motion: .motion
        }
    }
}

private extension TerminalExternalMouseButton {
    var backendButton: BackendTerminalMouseButton {
        switch self {
        case .left: .left
        case .right: .right
        case .middle: .middle
        case .wheelUp: .wheelUp
        case .wheelDown: .wheelDown
        case .wheelLeft: .wheelLeft
        case .wheelRight: .wheelRight
        }
    }
}

private extension TerminalBackendMutationOutcome {
    mutating func install(_ response: BackendTerminalActionResponse) {
        actionHandled = response.handled
        clipboardText = response.clipboardText
        install(response.state)
    }

    mutating func install(_ state: BackendTerminalUXState) {
        copyModeActive = state.copyMode
        mouseTracking = state.mouseTracking
        copyCursor = state.copyCursor?.externalPoint
        cursor = state.cursor?.externalCursor
        terminalUXWasRead = true
        selection = state.selection?.externalSelection
        selectionWasRead = true
        search = state.search.externalSearch
        viewportState = state.viewport.externalViewport
    }
}

private extension BackendTerminalSelection {
    var externalSelection: TerminalExternalSelection? {
        guard hasSelection, let range else { return nil }
        return TerminalExternalSelection(
            text: text ?? "",
            start: range.start.externalPoint,
            end: range.end.externalPoint,
            topLeft: range.topLeft.externalPoint,
            bottomRight: range.bottomRight.externalPoint,
            rectangle: range.rectangle
        )
    }
}

private extension BackendTerminalCursorState {
    var externalCursor: TerminalExternalCursorState {
        TerminalExternalCursorState(column: column, row: row, visible: visible)
    }
}

private extension BackendTerminalCellPoint {
    var externalPoint: TerminalExternalCellPoint {
        TerminalExternalCellPoint(column: column, row: row)
    }
}

private extension BackendTerminalSearchState {
    var externalSearch: TerminalExternalSearchState {
        TerminalExternalSearchState(
            active: active,
            query: query,
            selectedMatch: selectedMatch,
            totalMatches: totalMatches
        )
    }
}

private extension BackendTerminalViewportState {
    var externalViewport: TerminalExternalViewportState {
        TerminalExternalViewportState(
            totalRows: totalRows,
            offset: offset,
            visibleRows: visibleRows
        )
    }
}

private extension TerminalExternalSelectionOperation {
    var backendOperation: BackendTerminalSelectionOperation {
        switch self {
        case .read: .read
        case .clear: .clear
        case .selectAll: .selectAll
        }
    }
}

private extension TerminalExternalCopyModeOperation {
    var backendOperation: BackendTerminalCopyModeOperation {
        switch self {
        case .enter: .enter
        case .exit: .exit
        case .startSelection: .startSelection
        case .startLineSelection: .startLineSelection
        case .clearSelection: .clearSelection
        case .adjust: .adjust
        case .copyAndExit: .copyAndExit
        }
    }
}

private extension TerminalExternalCopyModeAdjustment {
    var backendAdjustment: BackendTerminalCopyModeAdjustment {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .beginningOfLine: .beginningOfLine
        case .endOfLine: .endOfLine
        }
    }
}

private extension TerminalExternalSearchOperation {
    var backendOperation: BackendTerminalSearchOperation {
        switch self {
        case .start: .start
        case .update: .update
        case .next: .next
        case .previous: .previous
        case .end: .end
        }
    }
}

private extension TerminalExternalScrollOperation {
    var backendOperation: BackendTerminalScrollOperation {
        switch self {
        case .lines: .lines
        case .pages: .pages
        case .top: .top
        case .bottom: .bottom
        }
    }
}

private extension TerminalRenderPixelFormat {
    var backendPixelFormat: BackendRendererPixelFormat {
        switch self {
        case .bgra8Unorm: .bgra8Unorm
        case .rgba16Float: .rgba16Float
        }
    }
}

private extension BackendRendererPixelFormat {
    var terminalPixelFormat: TerminalRenderPixelFormat {
        switch self {
        case .bgra8Unorm: .bgra8Unorm
        case .rgba16Float: .rgba16Float
        }
    }
}

private extension TerminalRenderColorSpace {
    var backendColorSpace: BackendRendererColorSpace {
        switch self {
        case .sRGB: .sRGB
        case .displayP3: .displayP3
        case .extendedLinearSRGB: .extendedLinearSRGB
        }
    }
}

private extension BackendRendererColorSpace {
    var terminalColorSpace: TerminalRenderColorSpace {
        switch self {
        case .sRGB: .sRGB
        case .displayP3: .displayP3
        case .extendedLinearSRGB: .extendedLinearSRGB
        }
    }
}
