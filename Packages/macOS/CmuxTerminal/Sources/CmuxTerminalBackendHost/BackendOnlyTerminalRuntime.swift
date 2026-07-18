internal import AppKit
public import CmuxTerminalBackend
public import CmuxTerminalFrontend
internal import CmuxTerminalRenderCompositor
internal import CmuxTerminalRenderProtocol
internal import CmuxTerminalRenderTransport
internal import Darwin
public import Foundation

final class BackendOnlyPresentedFrameState: @unchecked Sendable {
    struct ScheduledDrain: Sendable {
        let metadata: TerminalRenderFrameMetadata
        let accessibilityDemanded: Bool
    }

    private struct SemanticFrameKey: Equatable {
        let presentationID: UUID
        let presentationGeneration: UInt64
        let terminalSequence: UInt64
    }

    private let lock = NSLock()
    private var metadata: TerminalRenderFrameMetadata?
    private var semanticFrameKey: SemanticFrameKey?
    private var drainScheduled = false
    private var accessibilityDemanded = false

    func record(_ value: TerminalRenderFrameMetadata) -> Bool {
        lock.lock()
        metadata = value
        let key = SemanticFrameKey(
            presentationID: value.presentationID,
            presentationGeneration: value.presentationGeneration,
            terminalSequence: value.terminalSequence
        )
        guard semanticFrameKey != key else {
            lock.unlock()
            return false
        }
        semanticFrameKey = key
        guard !drainScheduled else {
            lock.unlock()
            return false
        }
        drainScheduled = true
        lock.unlock()
        return true
    }

    func takeScheduledDrain() -> ScheduledDrain? {
        lock.lock()
        guard drainScheduled, let metadata else {
            lock.unlock()
            return nil
        }
        drainScheduled = false
        let drain = ScheduledDrain(
            metadata: metadata,
            accessibilityDemanded: accessibilityDemanded
        )
        lock.unlock()
        return drain
    }

    func latest() -> TerminalRenderFrameMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return metadata
    }

    func demandAccessibility() -> TerminalRenderFrameMetadata? {
        lock.lock()
        guard !accessibilityDemanded else {
            lock.unlock()
            return nil
        }
        accessibilityDemanded = true
        let latestWithoutScheduledDrain = drainScheduled ? nil : metadata
        lock.unlock()
        return latestWithoutScheduledDrain
    }

    func reset() {
        lock.lock()
        metadata = nil
        semanticFrameKey = nil
        drainScheduled = false
        lock.unlock()
    }
}

private final class BackendOnlyPresentationLease: TerminalExternalPresentationLease,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var detached = false
    private let detachAction: @Sendable () -> Void

    init(detachAction: @escaping @Sendable () -> Void) {
        self.detachAction = detachAction
    }

    nonisolated func detach() {
        lock.lock()
        guard !detached else {
            lock.unlock()
            return
        }
        detached = true
        lock.unlock()
        detachAction()
    }

    deinit {
        detach()
    }
}

/// Visible-only terminal adapter for the backend-only experimental host.
///
/// The adapter owns one bounded mutation stream, one presentation, one Mach
/// frame receiver, and one single-blit compositor. It is created only for the
/// selected workspace and releases every presentation resource when hidden.
/// Canonical terminal state and the PTY remain in cmuxd throughout.
@MainActor
public final class BackendOnlyTerminalRuntime: TerminalExternalRuntime {
    private static let mutationCapacity = 64

    private struct RendererOperationWaiter {
        let identifier: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    public private(set) var snapshot = TerminalExternalRuntimeSnapshot(
        lifecycle: .unavailable
    )

    public let selection: BackendOnlyTerminalSelection

    private let session: BackendCanonicalSession
    private let workerMonitor = BackendOnlyRendererWorkerMonitor()
    private let mutationStream: AsyncStream<TerminalExternalRuntimeMutation>
    private let mutationContinuation: AsyncStream<TerminalExternalRuntimeMutation>.Continuation
    private let presentedFrameState = BackendOnlyPresentedFrameState()
    private var nextIngressSequence: UInt64 = 1
    private var mutationTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var eventTaskGeneration = UUID()
    private var presentationTask: Task<Void, any Error>?
    private var receiveTask: Task<Void, Never>?
    private var accessibilityRefreshTask: Task<Void, Never>?
    private var accessibilityRefreshRequested = false
    private var latestAccessibilityMetadata: TerminalRenderFrameMetadata?
    private var uxRefreshTask: Task<Void, Never>?
    private var uxRefreshRequested = false
    private var latestUXContentSequence: UInt64?
    private var hostControlState = BackendOnlyHostControlDrainState()
    private var hostControlTask: Task<Void, Never>?
    private var hostViewportTask: Task<Void, Never>?
    private var pendingHostViewport: TerminalExternalViewport?
    private var accessibilityContinuations: [
        UUID: AsyncStream<TerminalAccessibilitySnapshot>.Continuation
    ] = [:]

    private var attachmentIDs: Set<UUID> = []
    private var retired = false
    private var visible = false
    private var focused = false
    private var currentViewport: TerminalExternalViewport?
    private var presentation: BackendPresentation?
    private var receiver: TerminalRenderFrameReceiver?
    private var compositor: TerminalRenderCompositorView?
    private weak var surfaceView: TerminalFrontendSurfaceView?
    private var rendererEpoch: UInt64?
    private var rendererDaemonInstanceID: UUID?
    private var rendererGeneration: UInt64?
    private var rendererTerminalEpoch: UInt64?
    private var minimumContentSequence: UInt64?
    private var rendererMetrics: BackendRendererMetrics?
    private var workerIdentity: BackendOnlyRendererWorkerIdentity?
    private var workerExitFence: BackendOnlyRendererWorkerExitFence?
    private var configuredPixelSize: (width: UInt32, height: UInt32)?
    private var configuredViewport: TerminalExternalViewport?
    private var configuredFocus = false
    private var currentPreedit: TerminalExternalPreedit?
    private var rendererRestarting = false
    private var rendererOperationGeneration: UInt64 = 1
    private var rendererOperationLocked = false
    private var rendererOperationWaiters: [RendererOperationWaiter] = []

    public init(
        session: BackendCanonicalSession,
        selection: BackendOnlyTerminalSelection
    ) {
        self.session = session
        self.selection = selection
        let pair = AsyncStream<TerminalExternalRuntimeMutation>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.mutationCapacity)
        )
        mutationStream = pair.stream
        mutationContinuation = pair.continuation
        mutationTask = Task { [weak self, stream = pair.stream] in
            for await mutation in stream {
                guard let self else { return }
                await self.apply(mutation)
            }
        }
    }

    deinit {
        mutationContinuation.finish()
        mutationTask?.cancel()
        eventTask?.cancel()
        presentationTask?.cancel()
        receiveTask?.cancel()
        accessibilityRefreshTask?.cancel()
        uxRefreshTask?.cancel()
        hostControlTask?.cancel()
        hostViewportTask?.cancel()
    }

    /// Mounts compositor pixels below the Ghostty-free interaction view.
    public func bindSurfaceView(_ surfaceView: TerminalFrontendSurfaceView) {
        self.surfaceView = surfaceView
        if let compositor, compositor.superview !== surfaceView {
            install(compositor, in: surfaceView)
        }
    }

    public func attachPresentation(
        _ presentation: TerminalExternalPresentation
    ) -> any TerminalExternalPresentationLease {
        precondition(presentation.surfaceID == selection.surfaceID.rawValue)
        precondition(presentation.workspaceID == selection.workspaceID.rawValue)
        precondition(!retired)
        let attachmentID = UUID()
        attachmentIDs.insert(attachmentID)
        let runtime = self
        return BackendOnlyPresentationLease {
            Task { @MainActor in
                await runtime.detachPresentation(attachmentID: attachmentID)
            }
        }
    }

    public func adoptCanonicalPlacement(workspaceID: UUID) {
        precondition(workspaceID == selection.workspaceID.rawValue)
    }

    @discardableResult
    public func enqueue(
        _ mutation: TerminalExternalRuntimeMutation
    ) -> TerminalExternalIngressResult {
        guard !retired else { return .rejected(.unavailable) }
        guard nextIngressSequence != UInt64.max else {
            return .rejected(.queueFull)
        }
        let sequence = nextIngressSequence
        switch mutationContinuation.yield(mutation) {
        case .enqueued:
            nextIngressSequence += 1
            return .accepted(sequence: sequence)
        case .dropped:
            return .rejected(.queueFull)
        case .terminated:
            return .rejected(.unavailable)
        @unknown default:
            return .rejected(.unavailable)
        }
    }

    /// Retires the local presentation while preserving the daemon-owned PTY.
    ///
    /// Unlike normal input admission, this path cannot be dropped when the
    /// bounded mutation queue is full. The task that calls it retains the
    /// runtime until renderer control, frame leases, and the presentation are
    /// all released.
    public func shutdown() async {
        guard !retired else { return }
        presentationTask?.cancel()
        retired = true
        visible = false
        hostControlState.cancel()
        hostControlTask?.cancel()
        attachmentIDs.removeAll()
        invalidateRendererOperations()
        mutationContinuation.finish()
        mutationTask?.cancel()
        mutationTask = nil
        accessibilityRefreshTask?.cancel()
        accessibilityRefreshTask = nil
        uxRefreshTask?.cancel()
        uxRefreshTask = nil
        hostViewportTask?.cancel()
        hostViewportTask = nil
        pendingHostViewport = nil
        await withRendererOperationIgnoringCancellation {
            await self.stopPresentation()
        }
        for continuation in accessibilityContinuations.values {
            continuation.finish()
        }
        accessibilityContinuations.removeAll()
    }

    /// Applies host lifecycle state through a non-droppable control path.
    public func setHostVisibility(_ value: Bool) {
        guard !retired else { return }
        let shouldStartDrain = hostControlState.setVisibility(value)
        if !value {
            presentationTask?.cancel()
            visible = false
            pendingHostViewport = nil
            hostViewportTask?.cancel()
            invalidateRendererOperations()
        }
        guard shouldStartDrain else { return }
        startHostControlDrain()
    }

    /// Key-window focus is presentation state and must not be lost to input
    /// queue saturation.
    public func setHostFocus(_ value: Bool) {
        guard !retired else { return }
        let shouldStartDrain = hostControlState.setFocus(value)
        // Focus is desired renderer state. Publishing it immediately keeps
        // presentation startup and in-flight configuration on the newest value.
        focused = value
        guard shouldStartDrain else { return }
        startHostControlDrain()
    }

    private func startHostControlDrain() {
        guard hostControlTask == nil else { return }
        hostControlTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.hostControlTask = nil }

            while !Task.isCancelled {
                var shouldContinue = false
                await self.withRendererOperationIgnoringCancellation {
                    guard !self.retired,
                          let target = self.hostControlState.latestTarget()
                    else { return }
                    await self.applyHostControl(target)
                    shouldContinue = self.hostControlState.complete(target)
                }
                // A setter can run after completion marks the state idle but
                // before this task resumes from the renderer-operation await.
                // Keep this owner when that setter installed a fresh target.
                guard shouldContinue
                        || self.hostControlState.latestTarget() != nil
                else { return }
            }
        }
    }

    private func applyHostControl(
        _ target: BackendOnlyHostControlDrainState.Target
    ) async {
        guard !retired, hostControlState.isCurrent(target) else { return }

        if target.values.visible {
            await applySerialized(.focus(target.values.focused))
            guard !retired, hostControlState.isCurrent(target) else { return }
            await applySerialized(.visibility(true))
        } else {
            await applySerialized(.visibility(false))
            guard !retired, hostControlState.isCurrent(target) else { return }
            await applySerialized(.focus(target.values.focused))
        }
    }

    /// Coalesces live-resize geometry to the newest viewport while preserving
    /// strict input ordering in the separate bounded ingress.
    public func setHostViewport(_ viewport: TerminalExternalViewport) {
        guard !retired else { return }
        pendingHostViewport = viewport
        guard hostViewportTask == nil else { return }
        hostViewportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.hostViewportTask = nil
                if let pending = self.pendingHostViewport, !self.retired {
                    self.setHostViewport(pending)
                }
            }
            while !Task.isCancelled, let next = self.pendingHostViewport {
                self.pendingHostViewport = nil
                await self.withRendererOperationIgnoringCancellation {
                    await self.applySerialized(.resize(next))
                }
            }
        }
    }

    public func readScreenText(
        _ request: TerminalExternalScreenTextRequest
    ) async -> String? {
        do {
            let value = try await session.readTerminalScreen(
                surface: selection.numericSurfaceID
            ).text
            switch request {
            case .visible:
                return value
            case .vtTail(let maxRows, let maxBytes):
                return Self.boundedVTTail(
                    value,
                    maximumRows: maxRows,
                    maximumBytes: maxBytes
                )
            }
        } catch {
            return nil
        }
    }

    public func readSelection() async -> TerminalExternalSelection? {
        do {
            let response = try await session.terminalSelection(
                surfaceID: selection.surfaceID,
                operation: .read
            )
            installUXState(response.state)
            return Self.externalSelection(response.selection)
        } catch {
            return nil
        }
    }

    public func enableAccessibility() {
        guard let metadata = presentedFrameState.demandAccessibility() else { return }
        requestAccessibility(metadata)
    }

    public func accessibilitySnapshots() -> AsyncStream<TerminalAccessibilitySnapshot> {
        enableAccessibility()
        let identifier = UUID()
        let pair = AsyncStream<TerminalAccessibilitySnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        accessibilityContinuations[identifier] = pair.continuation
        if let value = snapshot.accessibility {
            pair.continuation.yield(value)
        }
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.accessibilityContinuations.removeValue(forKey: identifier)
            }
        }
        return pair.stream
    }

    public func activateAccessibilityLink(
        _ link: TerminalAccessibilityLink,
        snapshot requestedSnapshot: TerminalAccessibilitySnapshot
    ) async -> String? {
        guard let presentation,
              presentation.id.rawValue == requestedSnapshot.presentationID,
              presentation.generation == requestedSnapshot.presentationGeneration,
              snapshot.accessibility == requestedSnapshot,
              requestedSnapshot.links.contains(link)
        else { return nil }
        return try? await session.activateTerminalAccessibilityLink(
            presentationID: presentation.id,
            expectedGeneration: presentation.generation,
            terminalRevision: requestedSnapshot.terminalRevision,
            contentRevision: requestedSnapshot.contentRevision,
            viewportRevision: requestedSnapshot.viewportRevision,
            linkID: link.id
        ).target
    }

    public func activateHyperlink(
        at event: TerminalExternalMouseEvent
    ) async -> TerminalExternalHyperlinkHit? {
        guard let presentation,
              let metadata = presentedFrameState.latest(),
              let metrics = rendererMetrics,
              let point = Self.backendMouseEvent(event, metrics: metrics)
        else { return nil }
        guard let hit = try? await session.terminalHyperlinkAtCell(
            presentationID: presentation.id,
            expectedGeneration: presentation.generation,
            expectedContentSequence: metadata.terminalSequence,
            column: point.column,
            row: point.row
        ) else { return nil }
        return TerminalExternalHyperlinkHit(
            target: hit.target,
            contentSequence: hit.contentSequence,
            presentationGeneration: hit.presentationGeneration,
            column: hit.column,
            row: hit.row
        )
    }

    private func apply(_ mutation: TerminalExternalRuntimeMutation) async {
        do {
            try await withRendererOperation {
                await self.applySerialized(mutation)
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private func applySerialized(_ mutation: TerminalExternalRuntimeMutation) async {
        do {
            switch mutation {
            case .visibility(let value):
                visible = value
                if value {
                    try await startPresentationIfReady()
                } else {
                    await stopPresentation()
                }
            case .focus(let value):
                guard focused != value || configuredFocus != value else { return }
                focused = value
                if visible, presentation != nil, let currentViewport {
                    try await configureRenderer(viewport: currentViewport)
                }
            case .resize(let viewport):
                currentViewport = viewport
                if visible {
                    try await startPresentationIfReady()
                    try await resizeIfNeeded(viewport)
                }
            case .input(let input):
                try await send(input)
            case .preedit(let preedit):
                currentPreedit = preedit
                guard let presentation, let rendererGeneration else { return }
                try await session.setTerminalPreedit(
                    presentationID: presentation.id,
                    rendererGeneration: rendererGeneration,
                    preedit: preedit.map {
                        BackendTerminalPreedit(
                            text: $0.text,
                            selectionStartUTF16: $0.selectionStartUTF16,
                            selectionLengthUTF16: $0.selectionLengthUTF16,
                            caretUTF16: $0.caretUTF16
                        )
                    }
                )
            case .mouse(let event):
                try await send(event)
            case .bindingAction(let action, let repeatCount):
                let response = try await session.performTerminalBindingAction(
                    surfaceID: selection.surfaceID,
                    action: action,
                    repeatCount: repeatCount
                )
                install(response)
            case .selection(let operation):
                let response = try await session.terminalSelection(
                    surfaceID: selection.surfaceID,
                    operation: Self.backendSelectionOperation(operation)
                )
                installUXState(response.state)
            case .copyMode(let operation, let adjustment, let count):
                let response = try await session.terminalCopyMode(
                    surfaceID: selection.surfaceID,
                    operation: Self.backendCopyModeOperation(operation),
                    adjustment: adjustment.map(Self.backendCopyModeAdjustment),
                    count: count
                )
                install(response)
            case .search(let operation, let query):
                let response = try await session.terminalSearch(
                    surfaceID: selection.surfaceID,
                    operation: Self.backendSearchOperation(operation),
                    query: query
                )
                install(response)
            case .scroll(let operation, let amount):
                let response = try await session.terminalScroll(
                    surfaceID: selection.surfaceID,
                    operation: Self.backendScrollOperation(operation),
                    amount: amount
                )
                install(response)
            case .reparent(let workspaceID):
                guard workspaceID == selection.workspaceID.rawValue else {
                    throw BackendOnlyHostConnectionError.backendUnavailable
                }
            case .closeCanonicalTerminal:
                try await session.closeTerminal(surface: selection.numericSurfaceID)
                snapshot = TerminalExternalRuntimeSnapshot(lifecycle: .processExited)
                await stopPresentation()
            }
        } catch is CancellationError {
            return
        } catch {
            snapshot = TerminalExternalRuntimeSnapshot(lifecycle: .unavailable)
            await stopPresentation()
            if visible, !rendererRestarting {
                do {
                    try await startPresentationIfReady()
                } catch {
                    await stopPresentation()
                }
            }
        }
    }

    private func invalidateRendererOperations() {
        rendererOperationGeneration &+= 1
        if rendererOperationGeneration == 0 {
            rendererOperationGeneration = 1
        }
    }

    private func acquireRendererOperation(cancellable: Bool) async -> Bool {
        if !rendererOperationLocked {
            guard !cancellable || !Task.isCancelled else { return false }
            rendererOperationLocked = true
            return true
        }
        let identifier = UUID()
        if !cancellable {
            return await withCheckedContinuation { continuation in
                rendererOperationWaiters.append(RendererOperationWaiter(
                    identifier: identifier,
                    continuation: continuation
                ))
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    rendererOperationWaiters.append(RendererOperationWaiter(
                        identifier: identifier,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRendererOperationWaiter(identifier)
            }
        }
    }

    private func cancelRendererOperationWaiter(_ identifier: UUID) {
        guard let index = rendererOperationWaiters.firstIndex(where: {
            $0.identifier == identifier
        }) else { return }
        rendererOperationWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func releaseRendererOperation() {
        if rendererOperationWaiters.isEmpty {
            rendererOperationLocked = false
        } else {
            rendererOperationWaiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func withRendererOperation<Result>(
        _ operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        guard await acquireRendererOperation(cancellable: true) else {
            throw CancellationError()
        }
        defer { releaseRendererOperation() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func withRendererOperationIgnoringCancellation(
        _ operation: @MainActor () async -> Void
    ) async {
        guard await acquireRendererOperation(cancellable: false) else { return }
        defer { releaseRendererOperation() }
        await operation()
    }

    private func detachPresentation(attachmentID: UUID) async {
        guard attachmentIDs.remove(attachmentID) != nil,
              attachmentIDs.isEmpty else { return }
        presentationTask?.cancel()
        visible = false
        invalidateRendererOperations()
        await withRendererOperationIgnoringCancellation {
            await self.stopPresentation()
        }
    }

    private func startPresentationIfReady() async throws {
        guard !retired, !attachmentIDs.isEmpty, visible,
              presentation == nil, presentationTask == nil,
              let viewport = currentViewport,
              viewport.widthPixels > 1, viewport.heightPixels > 1
        else { return }
        let operationGeneration = rendererOperationGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.startPresentation(
                viewport: viewport,
                operationGeneration: operationGeneration
            )
        }
        presentationTask = task
        defer { presentationTask = nil }
        do {
            try await task.value
        } catch {
            await stopPresentation()
            throw error
        }
    }

    private func startPresentation(
        viewport: TerminalExternalViewport,
        operationGeneration: UInt64
    ) async throws {
        let opened = try await session.openPresentation(
            view: BackendPresentationView(
                workspaceID: selection.workspaceID,
                screenID: selection.screenID,
                paneID: selection.paneID,
                surfaceID: selection.surfaceID
            )
        )
        presentation = opened
        try validateRendererOperation(operationGeneration)
        let activation = try await session.activateTerminalPresentation(
            id: opened.id,
            expectedGeneration: opened.generation
        )
        guard activation.surfaceID == selection.surfaceID else {
            throw BackendOnlyHostConnectionError.backendUnavailable
        }
        try validateRendererOperation(operationGeneration)
        _ = try await session.acquireTerminalControl(
            surfaceID: selection.surfaceID,
            presentationID: opened.id,
            presentationGeneration: opened.generation
        )
        try validateRendererOperation(operationGeneration)
        startEventTaskIfNeeded()
        try await configureRenderer(viewport: viewport)
        try validateRendererOperation(operationGeneration)
        let state = try await session.terminalState(surfaceID: selection.surfaceID)
        try validateRendererOperation(operationGeneration)
        installUXState(state.state)
    }

    private func validateRendererOperation(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard !retired, !attachmentIDs.isEmpty, visible,
              rendererOperationGeneration == generation else {
            throw CancellationError()
        }
    }

    private func configureRenderer(viewport: TerminalExternalViewport) async throws {
        guard let presentation,
              let width = UInt32(exactly: viewport.widthPixels),
              let height = UInt32(exactly: viewport.heightPixels),
              width > 0, height > 0,
              let authority = await session.currentSnapshot()?.authority
        else { throw BackendOnlyHostConnectionError.backendUnavailable }

        let columns = UInt16(clamping: max(
            1,
            viewport.proposedColumns
                ?? snapshot.cellMetrics?.columns
                ?? viewport.widthPixels / 8
        ))
        let rows = UInt16(clamping: max(
            1,
            viewport.proposedRows
                ?? snapshot.cellMetrics?.rows
                ?? viewport.heightPixels / 16
        ))
        let receiver: TerminalRenderFrameReceiver
        if let existing = self.receiver {
            receiver = existing
        } else {
            let placeholder = try TerminalRenderPresentationFence(
                daemonInstanceID: authority.daemonInstanceID.rawValue,
                rendererEpoch: 1,
                terminalID: selection.surfaceID.rawValue,
                terminalEpoch: 0,
                minimumTerminalSequence: 0,
                presentationID: presentation.id.rawValue,
                presentationGeneration: 1,
                width: width,
                height: height,
                pixelFormat: .bgra8Unorm,
                colorSpace: .sRGB,
                completionRequirement: .producerCompleted
            )
            receiver = try TerminalRenderFrameReceiver(initialFence: placeholder)
            self.receiver = receiver
        }
        let preedit = currentPreedit
        // Capture exactly what this RPC carries. Host focus may change while
        // the daemon awaits the renderer, and configuredFocus must describe
        // the acknowledged request so the control drain can publish a follow-up.
        let requestedFocus = focused
        let requestedCursorBlinkVisibility = requestedFocus && visible
        let receipt = try await session.configureRendererPresentation(
            id: presentation.id,
            expectedGeneration: presentation.generation,
            configuration: BackendRendererPresentationConfiguration(
                width: width,
                height: height,
                backingScaleFactor: viewport.xScale,
                columns: columns,
                rows: rows,
                pixelFormat: .bgra8Unorm,
                colorSpace: .sRGB,
                frameEndpointService: receiver.endpoint.serviceName,
                frameEndpointCapability: receiver.endpoint.capability,
                resolvedConfigRevision: 0,
                resolvedConfig: Data(),
                focused: requestedFocus,
                cursorBlinkVisible: requestedCursorBlinkVisibility,
                preedit: preedit?.text,
                preeditSelectionStartUTF16: preedit?.selectionStartUTF16 ?? 0,
                preeditSelectionLengthUTF16: preedit?.selectionLengthUTF16 ?? 0,
                preeditCaretUTF16: preedit?.caretUTF16 ?? 0
            )
        )
        guard self.presentation?.id == presentation.id,
              self.presentation?.generation == presentation.generation,
              receipt.daemonInstanceID == authority.daemonInstanceID,
              receipt.workspaceID == selection.workspaceID,
              receipt.terminalID == selection.surfaceID,
              receipt.presentationID == presentation.id,
              receipt.canonicalGeneration == presentation.generation,
              receipt.width == width,
              receipt.height == height else {
            throw BackendOnlyHostConnectionError.backendUnavailable
        }
        // Worker authorization and the endpoint capability are write-once. Let
        // serialized recovery retire this presentation, then configure the
        // replacement worker with a fresh receiver and capability.
        if BackendOnlyRendererWorkerTransition.requiresReceiverRotation(
            currentWorker: workerIdentity,
            daemonInstanceID: receipt.daemonInstanceID.rawValue,
            rendererEpoch: receipt.rendererEpoch,
            state: receipt.workerState,
            processID: receipt.workerProcessID,
            effectiveUserID: receipt.workerEffectiveUserID,
            processInstanceToken: receipt.workerProcessInstanceToken
        ) {
            throw BackendOnlyHostConnectionError.backendUnavailable
        }
        configuredPixelSize = (width, height)
        configuredViewport = viewport
        configuredFocus = requestedFocus
        rendererDaemonInstanceID = receipt.daemonInstanceID.rawValue
        rendererEpoch = receipt.rendererEpoch
        rendererGeneration = receipt.rendererGeneration
        rendererTerminalEpoch = receipt.terminalEpoch
        minimumContentSequence = receipt.minimumContentSequence
        if receipt.workerState == .ready {
            try await activateConfiguredRenderer(receipt, receiver: receiver)
            if let metrics = receipt.metrics {
                installMetrics(metrics, width: width, height: height)
            }
        }
    }

    private func activateConfiguredRenderer(
        _ receipt: BackendRendererPresentationReceipt,
        receiver: TerminalRenderFrameReceiver
    ) async throws {
        guard let processID = receipt.workerProcessID,
              let effectiveUserID = receipt.workerEffectiveUserID,
              let processToken = receipt.workerProcessInstanceToken,
              let processID = pid_t(exactly: processID)
        else { throw BackendOnlyHostConnectionError.backendUnavailable }
        try await activateRenderer(
            daemonInstanceID: receipt.daemonInstanceID.rawValue,
            rendererEpoch: receipt.rendererEpoch,
            processID: processID,
            effectiveUserID: effectiveUserID,
            processToken: processToken,
            terminalEpoch: receipt.terminalEpoch,
            presentationGeneration: receipt.rendererGeneration,
            minimumContentSequence: receipt.minimumContentSequence,
            width: receipt.width,
            height: receipt.height,
            receiver: receiver
        )
    }

    private func activateReadyRenderer(
        _ ready: BackendRendererPresentationReady,
        daemonInstanceID: UUID,
        minimumContentSequence: UInt64,
        width: UInt32,
        height: UInt32,
        receiver: TerminalRenderFrameReceiver
    ) async throws {
        guard let processID = pid_t(exactly: ready.workerProcessID) else {
            throw BackendOnlyHostConnectionError.backendUnavailable
        }
        try await activateRenderer(
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: ready.rendererEpoch,
            processID: processID,
            effectiveUserID: ready.workerEffectiveUserID,
            processToken: ready.workerProcessInstanceToken,
            terminalEpoch: ready.terminalEpoch,
            presentationGeneration: ready.presentationGeneration,
            minimumContentSequence: minimumContentSequence,
            width: width,
            height: height,
            receiver: receiver
        )
    }

    private func activateRenderer(
        daemonInstanceID: UUID,
        rendererEpoch: UInt64,
        processID: pid_t,
        effectiveUserID: UInt32,
        processToken: BackendRendererProcessInstanceToken,
        terminalEpoch: UInt64,
        presentationGeneration: UInt64,
        minimumContentSequence: UInt64,
        width: UInt32,
        height: UInt32,
        receiver: TerminalRenderFrameReceiver
    ) async throws {
        guard let presentation,
              presentationGeneration == rendererGeneration,
              rendererDaemonInstanceID == daemonInstanceID,
              self.rendererEpoch == rendererEpoch,
              rendererTerminalEpoch == terminalEpoch else {
            throw BackendOnlyHostConnectionError.backendUnavailable
        }
        let identity = BackendOnlyRendererWorkerIdentity(
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: rendererEpoch,
            processID: processID,
            effectiveUserID: effectiveUserID,
            processInstanceToken: processToken
        )
        let runtime = self
        let exitFence: BackendOnlyRendererWorkerExitFence
        switch workerMonitor.watch(identity, onExit: { [weak runtime] exited in
            Task { @MainActor [weak runtime] in
                await runtime?.rendererWorkerExited(exited)
            }
        }) {
        case .watching(let fence):
            exitFence = fence
        case .alreadyExited, .unverifiable:
            throw BackendOnlyHostConnectionError.backendUnavailable
        }
        let authenticatedWorker = try TerminalRenderWorkerIdentity(
            processID: processID,
            effectiveUserID: effectiveUserID,
            processInstanceToken: TerminalRenderProcessInstanceToken(
                startTimeSeconds: processToken.startTimeSeconds,
                startTimeMicroseconds: processToken.startTimeMicroseconds
            )
        )
        try await receiver.authorize(worker: authenticatedWorker)
        let fence = try rendererFence(
            daemonInstanceID: identity.daemonInstanceID,
            rendererEpoch: identity.rendererEpoch,
            terminalEpoch: terminalEpoch,
            presentationGeneration: presentationGeneration,
            minimumContentSequence: minimumContentSequence,
            width: width,
            height: height
        )
        await receiver.updateFence(fence)
        let compositor = try installCompositor(fence: fence)
        workerIdentity = identity
        workerExitFence = exitFence
        startReceiving(receiver: receiver, ingress: compositor.frameIngress)
        do {
            guard !exitFence.hasExited else {
                throw BackendOnlyHostConnectionError.backendUnavailable
            }
            try await session.activateRendererPresentation(
                id: presentation.id,
                expectedGeneration: presentation.generation,
                rendererGeneration: presentationGeneration,
                rendererEpoch: rendererEpoch,
                workerProcessID: UInt32(processID),
                workerProcessInstanceToken: processToken
            )
            guard !exitFence.hasExited,
                  workerIdentity == identity,
                  self.presentation?.id == presentation.id,
                  self.presentation?.generation == presentation.generation else {
                throw BackendOnlyHostConnectionError.backendUnavailable
            }
        } catch {
            if workerIdentity == identity {
                workerIdentity = nil
                workerExitFence = nil
                workerMonitor.cancel(identity)
            }
            throw error
        }
    }

    private func installReadyEvent(
        _ ready: BackendRendererPresentationReady
    ) async throws {
        guard ready.workspaceID == selection.workspaceID,
              ready.presentationID == presentation?.id,
              ready.presentationGeneration == rendererGeneration,
              ready.terminalID == selection.surfaceID,
              ready.terminalEpoch == rendererTerminalEpoch,
              ready.rendererEpoch == rendererEpoch,
              let readyProcessID = pid_t(exactly: ready.workerProcessID),
              let configuredPixelSize,
              let receiver,
              let daemonInstanceID = rendererDaemonInstanceID
        else { return }
        let sequence = max(minimumContentSequence ?? 0, ready.canonicalSequence)
        if let identity = workerIdentity {
            guard identity.daemonInstanceID == daemonInstanceID,
                  identity.rendererEpoch == ready.rendererEpoch,
                  identity.processID == readyProcessID,
                  identity.effectiveUserID == ready.workerEffectiveUserID,
                  identity.processInstanceToken == ready.workerProcessInstanceToken,
                  workerExitFence?.hasExited == false else { return }
        } else {
            try await activateReadyRenderer(
                ready,
                daemonInstanceID: daemonInstanceID,
                minimumContentSequence: sequence,
                width: configuredPixelSize.width,
                height: configuredPixelSize.height,
                receiver: receiver
            )
        }
        let metrics = BackendRendererMetrics(
            columns: ready.columns,
            rows: ready.rows,
            cellWidth: ready.cellWidth,
            cellHeight: ready.cellHeight,
            padding: ready.padding
        )
        minimumContentSequence = sequence
        guard let identity = workerIdentity else {
            throw BackendOnlyHostConnectionError.backendUnavailable
        }
        let fence = try rendererFence(
            daemonInstanceID: identity.daemonInstanceID,
            rendererEpoch: ready.rendererEpoch,
            terminalEpoch: ready.terminalEpoch,
            presentationGeneration: ready.presentationGeneration,
            minimumContentSequence: sequence,
            width: configuredPixelSize.width,
            height: configuredPixelSize.height
        )
        await receiver.updateFence(fence)
        _ = try installCompositor(fence: fence)
        installMetrics(
            metrics,
            width: configuredPixelSize.width,
            height: configuredPixelSize.height
        )
    }

    private func rendererFence(
        daemonInstanceID: UUID,
        rendererEpoch: UInt64,
        terminalEpoch: UInt64,
        presentationGeneration: UInt64,
        minimumContentSequence: UInt64,
        width: UInt32,
        height: UInt32
    ) throws -> TerminalRenderPresentationFence {
        guard let presentation else {
            throw BackendOnlyHostConnectionError.backendUnavailable
        }
        return try TerminalRenderPresentationFence(
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: rendererEpoch,
            terminalID: selection.surfaceID.rawValue,
            terminalEpoch: terminalEpoch,
            minimumTerminalSequence: minimumContentSequence,
            presentationID: presentation.id.rawValue,
            presentationGeneration: presentationGeneration,
            width: width,
            height: height,
            pixelFormat: .bgra8Unorm,
            colorSpace: .sRGB,
            completionRequirement: .producerCompleted
        )
    }

    private func installCompositor(
        fence: TerminalRenderPresentationFence
    ) throws -> TerminalRenderCompositorView {
        let compositor: TerminalRenderCompositorView
        if let existing = self.compositor {
            existing.updateFence(fence)
            compositor = existing
        } else {
            let session = session
            let presentedFrameState = presentedFrameState
            let runtime = self
            compositor = try TerminalRenderCompositorView(
                fence: fence,
                frameReleaseHandler: { release in
                    Task {
                        _ = try? await session.releaseRendererFrame(
                            Self.backendRelease(release)
                        )
                    }
                },
                framePresentedHandler: { metadata in
                    guard presentedFrameState.record(metadata) else { return }
                    Task { @MainActor [weak runtime] in
                        guard let drain = presentedFrameState.takeScheduledDrain() else { return }
                        runtime?.didPresentFrame(
                            drain.metadata,
                            accessibilityDemanded: drain.accessibilityDemanded
                        )
                    }
                }
            )
            self.compositor = compositor
            if let surfaceView {
                install(compositor, in: surfaceView)
            }
        }
        return compositor
    }

    private func installMetrics(
        _ metrics: BackendRendererMetrics,
        width: UInt32,
        height: UInt32
    ) {
        rendererMetrics = metrics
        let backingScale = max(currentViewport?.xScale ?? 1, 1)
        snapshot = TerminalExternalRuntimeSnapshot(
            lifecycle: .live,
            cellMetrics: TerminalExternalCellMetrics(
                columns: Int(metrics.columns),
                rows: Int(metrics.rows),
                cellWidthPixels: Int(metrics.cellWidth),
                cellHeightPixels: Int(metrics.cellHeight),
                surfaceWidthPixels: Int(width),
                surfaceHeightPixels: Int(height),
                backingScale: backingScale,
                paddingLeftPixels: Int(metrics.padding.left),
                paddingTopPixels: Int(metrics.padding.top),
                paddingRightPixels: Int(metrics.padding.right),
                paddingBottomPixels: Int(metrics.padding.bottom)
            ),
            cursor: snapshot.cursor,
            selection: snapshot.selection,
            search: snapshot.search,
            viewportState: snapshot.viewportState,
            accessibility: snapshot.accessibility
        )
    }

    private func startReceiving(
        receiver: TerminalRenderFrameReceiver,
        ingress: TerminalRenderCompositorIngress
    ) {
        guard receiveTask == nil else { return }
        let session = session
        receiveTask = Task.detached {
            do {
                while !Task.isCancelled {
                    switch try await receiver.receive(
                        timeoutMilliseconds: TerminalRenderFrameReceiver
                            .maximumReceiveTimeoutMilliseconds
                    ) {
                    case .frame(let frame):
                        _ = await ingress.enqueue(frame)
                    case .dropped(_, let release):
                        if let release {
                            _ = try? await session.releaseRendererFrame(
                                Self.backendRelease(release)
                            )
                        }
                    case .timedOut:
                        continue
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func startEventTaskIfNeeded() {
        guard eventTask == nil else { return }
        let session = session
        let generation = UUID()
        eventTaskGeneration = generation
        eventTask = Task { @MainActor [weak self] in
            let events = await session.events()
            for await event in events {
                guard let self, self.visible, !self.retired else { return }
                await self.handleSessionEvent(event)
            }
            guard let self, !Task.isCancelled,
                  self.eventTaskGeneration == generation else { return }
            self.eventTask = nil
            await self.handleEventStreamEnded()
        }
    }

    private func handleSessionEvent(_ event: BackendCanonicalSessionEvent) async {
        do {
            try await withRendererOperation {
                switch event {
                case .rendererPresentationReady(let ready):
                    try await self.installReadyEvent(ready)
                case .rendererWorkerChanged(let changed):
                    guard changed.workspaceID == self.selection.workspaceID,
                          !self.rendererRestarting,
                          BackendOnlyRendererWorkerTransition.action(
                            currentRendererEpoch: self.rendererEpoch,
                            priorRendererEpoch: changed.priorRendererEpoch,
                            rendererEpoch: changed.rendererEpoch,
                            state: changed.state
                          ) == .restart else { return }
                    self.snapshot = TerminalExternalRuntimeSnapshot(lifecycle: .unavailable)
                    self.rendererRestarting = true
                    self.invalidateRendererOperations()
                    await self.stopPresentation(keepEventSubscription: true)
                    self.rendererRestarting = false
                    if self.visible, !self.retired {
                        try await self.startPresentationIfReady()
                    }
                case .disconnected:
                    self.snapshot = TerminalExternalRuntimeSnapshot(lifecycle: .unavailable)
                    self.invalidateRendererOperations()
                    await self.stopPresentation()
                case .snapshot, .delta, .terminalActivitySnapshot, .terminalActivity,
                     .terminalActivityReceipt:
                    return
                }
            }
        } catch {
            return
        }
    }

    private func handleEventStreamEnded() async {
        guard visible, !retired else { return }
        invalidateRendererOperations()
        await withRendererOperationIgnoringCancellation {
            await self.stopPresentation(keepEventSubscription: true)
            if self.visible, !self.retired {
                _ = try? await self.startPresentationIfReady()
            }
        }
    }

    private func rendererWorkerExited(
        _ identity: BackendOnlyRendererWorkerIdentity
    ) async {
        await withRendererOperationIgnoringCancellation {
            guard self.workerIdentity == identity, !self.rendererRestarting else { return }
            self.snapshot = TerminalExternalRuntimeSnapshot(lifecycle: .unavailable)
            self.workerIdentity = nil
            self.workerExitFence = nil
            self.rendererRestarting = true
            self.invalidateRendererOperations()
            await self.stopPresentation(keepEventSubscription: true)
            self.rendererRestarting = false
            if self.visible, !self.retired {
                _ = try? await self.startPresentationIfReady()
            }
        }
    }

    private func resizeIfNeeded(_ viewport: TerminalExternalViewport) async throws {
        guard presentation != nil,
              viewport != configuredViewport || focused != configuredFocus else { return }
        try await configureRenderer(viewport: viewport)
    }

    private func stopPresentation(keepEventSubscription: Bool = false) async {
        let priorWorkerIdentity = workerIdentity
        workerIdentity = nil
        workerExitFence = nil
        if let priorWorkerIdentity {
            workerMonitor.cancel(priorWorkerIdentity)
        }
        presentationTask?.cancel()
        presentationTask = nil
        if !keepEventSubscription {
            eventTaskGeneration = UUID()
            eventTask?.cancel()
            eventTask = nil
        }
        receiveTask?.cancel()
        if let receiveTask { await receiveTask.value }
        self.receiveTask = nil
        compositor?.retire()
        compositor?.removeFromSuperview()
        compositor = nil
        presentedFrameState.reset()
        accessibilityRefreshTask?.cancel()
        accessibilityRefreshTask = nil
        accessibilityRefreshRequested = false
        latestAccessibilityMetadata = nil
        uxRefreshTask?.cancel()
        uxRefreshTask = nil
        uxRefreshRequested = false
        latestUXContentSequence = nil
        clearAccessibilitySnapshot()

        if let presentation {
            _ = try? await session.detachRendererPresentation(
                id: presentation.id,
                expectedGeneration: presentation.generation
            )
            if let receiver {
                if let releases = try? await receiver.drainQuiescedFrames() {
                    for release in releases {
                        _ = try? await session.releaseRendererFrame(Self.backendRelease(release))
                    }
                }
                await receiver.stop()
            }
            _ = try? await session.releaseTerminalControl(
                surfaceID: selection.surfaceID,
                presentationID: presentation.id,
                presentationGeneration: presentation.generation
            )
            _ = try? await session.closePresentation(id: presentation.id)
        }
        presentation = nil
        receiver = nil
        rendererDaemonInstanceID = nil
        rendererEpoch = nil
        rendererGeneration = nil
        rendererTerminalEpoch = nil
        minimumContentSequence = nil
        rendererMetrics = nil
        configuredPixelSize = nil
        configuredViewport = nil
        configuredFocus = false
        if !visible {
            snapshot = TerminalExternalRuntimeSnapshot(lifecycle: .unavailable)
        }
    }

    private func send(_ input: TerminalExternalInput) async throws {
        guard let presentation else { throw BackendOnlyHostConnectionError.backendUnavailable }
        let backend: BackendTerminalControlInput = switch input {
        case .text(let value):
            .text(value.text, paste: value.kind == .paste)
        case .namedKey(let value):
            .namedKey(value)
        case .key(let value):
            .key(BackendTerminalKeyEvent(
                key: value.key,
                modifiers: value.modifiers.rawValue,
                consumedModifiers: value.consumedModifiers.rawValue,
                text: value.text ?? "",
                unshiftedCodepoint: value.unshiftedCodepoint,
                action: Self.backendKeyAction(value.action)
            ))
        }
        _ = try await session.sendTerminalInput(
            surfaceID: selection.surfaceID,
            presentationID: presentation.id,
            presentationGeneration: presentation.generation,
            requestID: UUID(),
            input: backend
        )
    }

    private func send(_ event: TerminalExternalMouseEvent) async throws {
        guard let presentation,
              let metrics = rendererMetrics,
              let backend = Self.backendMouseEvent(event, metrics: metrics)
        else { throw BackendOnlyHostConnectionError.backendUnavailable }
        _ = try await session.sendTerminalInput(
            surfaceID: selection.surfaceID,
            presentationID: presentation.id,
            presentationGeneration: presentation.generation,
            requestID: UUID(),
            input: .mouse(backend)
        )
    }

    private func install(_ response: BackendTerminalActionResponse) {
        installUXState(response.state)
        if let clipboard = response.clipboardText, !clipboard.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(clipboard, forType: .string)
        }
    }

    private func installUXState(_ state: BackendTerminalUXState) {
        snapshot = TerminalExternalRuntimeSnapshot(
            lifecycle: presentation == nil ? .unavailable : .live,
            cellMetrics: snapshot.cellMetrics,
            copyModeActive: state.copyMode,
            mouseTracking: state.mouseTracking,
            copyCursor: state.copyCursor.map {
                TerminalExternalCellPoint(column: $0.column, row: $0.row)
            },
            cursor: state.cursor.map {
                TerminalExternalCursorState(
                    column: $0.column,
                    row: $0.row,
                    visible: $0.visible
                )
            },
            selection: Self.externalSelection(state.selection),
            search: TerminalExternalSearchState(
                active: state.search.active,
                query: state.search.query,
                selectedMatch: state.search.selectedMatch,
                totalMatches: state.search.totalMatches
            ),
            viewportState: TerminalExternalViewportState(
                totalRows: state.viewport.totalRows,
                offset: state.viewport.offset,
                visibleRows: state.viewport.visibleRows
            ),
            accessibility: snapshot.accessibility
        )
    }

    private func didPresentFrame(
        _ metadata: TerminalRenderFrameMetadata,
        accessibilityDemanded: Bool
    ) {
        guard let presentation,
              presentation.id.rawValue == metadata.presentationID,
              rendererGeneration == metadata.presentationGeneration else { return }
        if latestUXContentSequence != metadata.terminalSequence {
            latestUXContentSequence = metadata.terminalSequence
            requestUXRefresh()
        }
        if accessibilityDemanded {
            requestAccessibility(metadata)
        }
    }

    private func requestUXRefresh() {
        guard presentation != nil, visible, !retired else { return }
        if uxRefreshTask != nil {
            uxRefreshRequested = true
            return
        }
        uxRefreshRequested = false
        uxRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.uxRefreshTask = nil
                if self.uxRefreshRequested {
                    self.requestUXRefresh()
                }
            }
            repeat {
                self.uxRefreshRequested = false
                guard let presentation = self.presentation else { return }
                do {
                    let response = try await self.session.terminalState(
                        surfaceID: self.selection.surfaceID
                    )
                    guard !Task.isCancelled,
                          self.presentation?.id == presentation.id,
                          self.presentation?.generation == presentation.generation,
                          response.surfaceID == self.selection.surfaceID else { return }
                    self.installUXState(response.state)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            } while self.uxRefreshRequested && !Task.isCancelled
        }
    }

    private func requestAccessibility(_ metadata: TerminalRenderFrameMetadata) {
        guard let presentation,
              presentation.id.rawValue == metadata.presentationID,
              rendererGeneration == metadata.presentationGeneration else { return }
        let priorMetadata = latestAccessibilityMetadata
        latestAccessibilityMetadata = metadata
        if accessibilityRefreshTask != nil {
            if priorMetadata?.terminalSequence != metadata.terminalSequence
                || priorMetadata?.presentationGeneration != metadata.presentationGeneration
                || priorMetadata?.presentationID != metadata.presentationID {
                accessibilityRefreshRequested = true
            }
            return
        }
        accessibilityRefreshRequested = false
        accessibilityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.accessibilityRefreshTask = nil
                if self.accessibilityRefreshRequested {
                    self.requestAccessibilityFromLatestFrame()
                }
            }
            repeat {
                self.accessibilityRefreshRequested = false
                guard let expected = self.latestAccessibilityMetadata,
                      let presentation = self.presentation,
                      presentation.id.rawValue == expected.presentationID,
                      self.rendererGeneration == expected.presentationGeneration else { return }
                do {
                    let value = try await self.session.terminalAccessibilitySnapshot(
                        presentationID: presentation.id,
                        expectedGeneration: presentation.generation,
                        expectedContentSequence: expected.terminalSequence
                    )
                    guard !Task.isCancelled,
                          self.presentation?.id == presentation.id,
                          self.presentation?.generation == presentation.generation,
                          self.rendererGeneration == expected.presentationGeneration,
                          self.latestAccessibilityMetadata?.terminalSequence
                            == expected.terminalSequence else {
                        self.accessibilityRefreshRequested = true
                        continue
                    }
                    self.installAccessibility(Self.externalAccessibility(value))
                } catch is CancellationError {
                    return
                } catch {
                    if self.latestAccessibilityMetadata?.terminalSequence
                        != expected.terminalSequence {
                        self.accessibilityRefreshRequested = true
                    }
                }
            } while self.accessibilityRefreshRequested && !Task.isCancelled
        }
    }

    private func requestAccessibilityFromLatestFrame() {
        guard let metadata = latestAccessibilityMetadata else { return }
        requestAccessibility(metadata)
    }

    private func installAccessibility(_ converted: TerminalAccessibilitySnapshot) {
        let prior = snapshot.accessibility
        guard prior?.presentationID != converted.presentationID
                || prior?.presentationGeneration != converted.presentationGeneration
                || prior?.terminalRevision != converted.terminalRevision
                || prior?.contentRevision != converted.contentRevision
                || prior?.viewportRevision != converted.viewportRevision else { return }
        snapshot = TerminalExternalRuntimeSnapshot(
            lifecycle: snapshot.lifecycle,
            visibleText: snapshot.visibleText,
            cellMetrics: snapshot.cellMetrics,
            processMetadata: snapshot.processMetadata,
            needsCloseConfirmation: snapshot.needsCloseConfirmation,
            copyModeActive: snapshot.copyModeActive,
            mouseTracking: snapshot.mouseTracking,
            copyCursor: snapshot.copyCursor,
            cursor: snapshot.cursor,
            selection: snapshot.selection,
            search: snapshot.search,
            viewportState: snapshot.viewportState,
            accessibility: converted
        )
        for continuation in accessibilityContinuations.values {
            continuation.yield(converted)
        }
    }

    private func clearAccessibilitySnapshot() {
        guard snapshot.accessibility != nil else { return }
        snapshot = TerminalExternalRuntimeSnapshot(
            lifecycle: snapshot.lifecycle,
            visibleText: snapshot.visibleText,
            cellMetrics: snapshot.cellMetrics,
            processMetadata: snapshot.processMetadata,
            needsCloseConfirmation: snapshot.needsCloseConfirmation,
            copyModeActive: snapshot.copyModeActive,
            mouseTracking: snapshot.mouseTracking,
            copyCursor: snapshot.copyCursor,
            cursor: snapshot.cursor,
            selection: snapshot.selection,
            search: snapshot.search,
            viewportState: snapshot.viewportState,
            accessibility: nil
        )
    }

    private func install(_ compositor: TerminalRenderCompositorView, in view: NSView) {
        compositor.frame = view.bounds
        compositor.autoresizingMask = [.width, .height]
        view.addSubview(compositor)
    }
}

private extension BackendOnlyTerminalRuntime {
    static func boundedVTTail(
        _ value: String,
        maximumRows: Int,
        maximumBytes: Int
    ) -> String {
        guard maximumRows > 0, maximumBytes > 0 else { return "" }
        let rowTail = value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maximumRows)
            .joined(separator: "\n")
        var start = rowTail.endIndex
        var retainedBytes = 0
        while start > rowTail.startIndex {
            let prior = rowTail.index(before: start)
            let characterBytes = rowTail[prior ..< start].utf8.count
            guard retainedBytes + characterBytes <= maximumBytes else { break }
            retainedBytes += characterBytes
            start = prior
        }
        return String(rowTail[start...])
    }

    static func backendRelease(
        _ release: TerminalRenderFrameRelease
    ) -> BackendRendererFrameRelease {
        BackendRendererFrameRelease(
            daemonInstanceID: DaemonInstanceID(rawValue: release.metadata.daemonInstanceID),
            rendererEpoch: release.metadata.rendererEpoch,
            terminalID: SurfaceID(rawValue: release.metadata.terminalID),
            terminalEpoch: release.metadata.terminalEpoch,
            terminalSequence: release.metadata.terminalSequence,
            presentationID: PresentationID(rawValue: release.metadata.presentationID),
            presentationGeneration: release.metadata.presentationGeneration,
            frameSequence: release.metadata.frameSequence,
            surfaceID: release.surfaceID
        )
    }

    static func backendMouseEvent(
        _ event: TerminalExternalMouseEvent,
        metrics: BackendRendererMetrics
    ) -> BackendTerminalCellMouseEvent? {
        BackendTerminalCellMouseEvent(
            action: backendMouseAction(event.action),
            button: event.button.map(backendMouseButton),
            modifiers: event.modifiers.rawValue,
            x: event.xPixels,
            y: event.yPixels,
            columns: metrics.columns,
            rows: metrics.rows,
            cellWidth: metrics.cellWidth,
            cellHeight: metrics.cellHeight,
            padding: metrics.padding,
            anyButtonPressed: event.anyButtonPressed,
            clickCount: event.clickCount
        )
    }

    static func externalSelection(
        _ selection: BackendTerminalSelection?
    ) -> TerminalExternalSelection? {
        guard let selection, selection.hasSelection,
              let text = selection.text, let range = selection.range else { return nil }
        return TerminalExternalSelection(
            text: text,
            start: TerminalExternalCellPoint(
                column: range.start.column,
                row: range.start.row
            ),
            end: TerminalExternalCellPoint(
                column: range.end.column,
                row: range.end.row
            ),
            topLeft: TerminalExternalCellPoint(
                column: range.topLeft.column,
                row: range.topLeft.row
            ),
            bottomRight: TerminalExternalCellPoint(
                column: range.bottomRight.column,
                row: range.bottomRight.row
            ),
            rectangle: range.rectangle
        )
    }

    static func externalAccessibility(
        _ value: BackendTerminalAccessibilitySnapshot
    ) -> TerminalAccessibilitySnapshot {
        TerminalAccessibilitySnapshot(
            schemaVersion: value.schemaVersion,
            surfaceID: value.surfaceID.rawValue,
            presentationID: value.presentationID.rawValue,
            presentationGeneration: value.presentationGeneration,
            contentSequence: value.contentSequence,
            terminalRevision: value.terminalRevision,
            contentRevision: value.contentRevision,
            viewportRevision: value.viewportRevision,
            viewportOffset: value.viewportOffset,
            columns: Int(value.columns),
            rows: Int(value.rows),
            text: value.text,
            lines: value.lines.map {
                TerminalAccessibilityLine(
                    row: $0.row,
                    utf16Range: TerminalAccessibilityRange(
                        location: Int($0.utf16Range.location),
                        length: Int($0.utf16Range.length)
                    ),
                    cells: $0.cells.map {
                        TerminalAccessibilityCell(
                            column: Int($0.column),
                            columnSpan: Int($0.columnSpan),
                            utf16Range: TerminalAccessibilityRange(
                                location: Int($0.utf16Range.location),
                                length: Int($0.utf16Range.length)
                            )
                        )
                    }
                )
            },
            cursor: value.cursor.map {
                TerminalAccessibilityCursor(
                    column: Int($0.column),
                    row: $0.row,
                    insertionRange: TerminalAccessibilityRange(
                        location: Int($0.insertionRange.location),
                        length: Int($0.insertionRange.length)
                    ),
                    line: Int($0.line)
                )
            },
            selections: value.selections.map {
                TerminalAccessibilitySelection(
                    text: $0.text,
                    utf16Ranges: $0.utf16Ranges.map {
                        TerminalAccessibilityRange(
                            location: Int($0.location),
                            length: Int($0.length)
                        )
                    }
                )
            },
            links: value.links.map {
                TerminalAccessibilityLink(
                    id: $0.id,
                    target: $0.target,
                    utf16Range: TerminalAccessibilityRange(
                        location: Int($0.utf16Range.location),
                        length: Int($0.utf16Range.length)
                    ),
                    row: $0.row,
                    startColumn: Int($0.startColumn),
                    endColumn: Int($0.endColumn)
                )
            },
            focused: value.focused
        )
    }

    static func backendMouseAction(
        _ value: TerminalExternalMouseAction
    ) -> BackendTerminalMouseAction {
        switch value {
        case .press: .press
        case .release: .release
        case .motion: .motion
        }
    }

    static func backendKeyAction(
        _ value: TerminalExternalKeyAction
    ) -> BackendTerminalKeyAction {
        switch value {
        case .press: .press
        case .release: .release
        case .repeat: .repeat
        }
    }

    static func backendMouseButton(
        _ value: TerminalExternalMouseButton
    ) -> BackendTerminalMouseButton {
        switch value {
        case .left: .left
        case .right: .right
        case .middle: .middle
        case .wheelUp: .wheelUp
        case .wheelDown: .wheelDown
        case .wheelLeft: .wheelLeft
        case .wheelRight: .wheelRight
        }
    }

    static func backendSelectionOperation(
        _ value: TerminalExternalSelectionOperation
    ) -> BackendTerminalSelectionOperation {
        switch value {
        case .read: .read
        case .clear: .clear
        case .selectAll: .selectAll
        }
    }

    static func backendCopyModeOperation(
        _ value: TerminalExternalCopyModeOperation
    ) -> BackendTerminalCopyModeOperation {
        switch value {
        case .enter: .enter
        case .exit: .exit
        case .startSelection: .startSelection
        case .startLineSelection: .startLineSelection
        case .clearSelection: .clearSelection
        case .adjust: .adjust
        case .copyAndExit: .copyAndExit
        }
    }

    static func backendCopyModeAdjustment(
        _ value: TerminalExternalCopyModeAdjustment
    ) -> BackendTerminalCopyModeAdjustment {
        switch value {
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

    static func backendSearchOperation(
        _ value: TerminalExternalSearchOperation
    ) -> BackendTerminalSearchOperation {
        switch value {
        case .start: .start
        case .update: .update
        case .next: .next
        case .previous: .previous
        case .end: .end
        }
    }

    static func backendScrollOperation(
        _ value: TerminalExternalScrollOperation
    ) -> BackendTerminalScrollOperation {
        switch value {
        case .lines: .lines
        case .pages: .pages
        case .top: .top
        case .bottom: .bottom
        }
    }
}
