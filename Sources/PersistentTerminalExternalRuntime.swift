import CmuxTerminal
import CmuxTerminalRenderCompositor
import CmuxTerminalRenderProtocol
import CmuxTerminalRenderTransport
import Foundation

/// Stops normal frame presentation from scheduling any main-actor work until
/// an accessibility client explicitly asks for terminal semantics.
private final class TerminalBackendAccessibilityFrameDemand: @unchecked Sendable {
    private let lock = NSLock()
    private var demanded = false

    func enable() {
        lock.lock()
        demanded = true
        lock.unlock()
    }

    func disable() {
        lock.lock()
        demanded = false
        lock.unlock()
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return demanded
    }
}

/// Cooperative stop flag for a detached Mach receive loop.
///
/// Cancellation can abandon a message after the kernel transferred its
/// IOSurface right but before Swift returned the worker's exact lease. Normal
/// rotation therefore asks the loop to stop at a receive boundary instead.
private final class TerminalBackendFrameReceiveLoopControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false

    func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }
}

private struct TerminalBackendReceiverRetirement: Sendable {
    let receiver: TerminalRenderFrameReceiver
    let receiveTask: Task<Void, Never>?
    let receiveLoopControl: TerminalBackendFrameReceiveLoopControl?
}

/// Retries one renderer operation only when the ordered renderer lifecycle
/// advances. Subscribing before the first attempt closes the disconnect race:
/// a reconnect that overlaps a failed RPC is buffered and wakes the retry.
func retryRendererOperationOnLifecycleChange(
    client: any TerminalBackendClient,
    operation: @escaping @Sendable () async throws -> Void
) async -> Bool {
    while !Task.isCancelled {
        let events = await client.rendererEvents()
        var iterator = events.makeAsyncIterator()
        do {
            try await operation()
            return true
        } catch {
            var lifecycleAdvanced = false
            while !lifecycleAdvanced {
                guard let event = await iterator.next() else {
                    // Stream replacement is itself a connection-boundary
                    // signal. Re-subscribe before retrying so an overflowed
                    // observer cannot silently abandon an exact receipt.
                    lifecycleAdvanced = true
                    continue
                }
                switch event {
                case .connectionLost, .reconnected, .workerChanged:
                    lifecycleAdvanced = true
                case .presentationReady:
                    continue
                }
            }
        }
    }
    return false
}

/// Retries the canonical detach until cmuxd proves worker quiescence. The
/// caller keeps its retired ingress active during this wait, so a reconnecting
/// worker cannot strand a frame lease in a destroyed endpoint.
func awaitRendererPresentationQuiescence(
    client: any TerminalBackendClient,
    presentationID: UUID,
    binding: TerminalBackendTerminalBinding?
) async -> Bool {
    await retryRendererOperationOnLifecycleChange(client: client) {
        try await client.detachPresentation(
            presentationID: presentationID,
            from: binding
        )
    }
}

/// Returns one exact lease across transient daemon disconnects. At most three
/// leases exist per presentation, so retries remain strictly bounded by the
/// worker pool while preventing a temporary socket failure from exhausting it.
@discardableResult
func returnRendererFrameLease(
    client: any TerminalBackendClient,
    release: TerminalRenderFrameRelease
) async -> Bool {
    await retryRendererOperationOnLifecycleChange(client: client) {
        try await client.releaseFrame(release)
    }
}

/// Thread-safe record of the newest frame Core Animation actually presented.
///
/// The Metal callback records this off the main actor. Hyperlink hit testing and
/// late accessibility activation can then fence semantic reads to visible pixels
/// without scheduling main-actor work for every frame.
final class TerminalBackendPresentedFrameState: @unchecked Sendable {
    private let lock = NSLock()
    private var fence: TerminalRenderPresentationFence?
    private var metadata: TerminalRenderFrameMetadata?

    func install(_ fence: TerminalRenderPresentationFence) {
        lock.lock()
        self.fence = fence
        metadata = nil
        lock.unlock()
    }

    func record(_ candidate: TerminalRenderFrameMetadata) {
        lock.lock()
        defer { lock.unlock() }
        guard let fence else { return }
        var acceptance = TerminalRenderFrameAcceptance()
        guard acceptance.accept(candidate, against: fence) == nil else { return }
        if let metadata,
           metadata.daemonInstanceID == candidate.daemonInstanceID,
           metadata.rendererEpoch == candidate.rendererEpoch,
           metadata.terminalID == candidate.terminalID,
           metadata.terminalEpoch == candidate.terminalEpoch,
           metadata.presentationID == candidate.presentationID,
           metadata.presentationGeneration == candidate.presentationGeneration,
           metadata.frameSequence >= candidate.frameSequence {
            return
        }
        metadata = candidate
    }

    func latest(matching fence: TerminalRenderPresentationFence) -> TerminalRenderFrameMetadata? {
        lock.lock()
        guard self.fence == fence else {
            lock.unlock()
            return nil
        }
        let candidate = metadata
        lock.unlock()
        guard let candidate else { return nil }
        var acceptance = TerminalRenderFrameAcceptance()
        guard acceptance.accept(candidate, against: fence) == nil else { return nil }
        return candidate
    }

    func latest() -> TerminalRenderFrameMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return metadata
    }

    func reset() {
        lock.lock()
        fence = nil
        metadata = nil
        lock.unlock()
    }
}

/// Main-actor façade over one daemon-owned terminal and its disposable presentation.
@MainActor
final class PersistentTerminalExternalRuntime: TerminalExternalRuntime {
    private enum State {
        case binding
        case live
        case processExited
        case unavailable
    }

    private let client: any TerminalBackendClient
    private let launchRequest: TerminalSurfaceLaunchRequest
    private let resolveLaunch: @MainActor (
        TerminalSurfaceLaunchRequest
    ) async -> TerminalSurfaceResolvedLaunch
    private let initialColumns: UInt16
    private let initialRows: UInt16
    private let presentationRegistry: TerminalBackendPresentationRegistry
    private var presentationID = UUID()
    private let pixelFormat = TerminalRenderPixelFormat.bgra8Unorm
    private let colorSpace = TerminalRenderColorSpace.sRGB
    private let renderConfigSource: TerminalBackendRenderConfigSource?
    private let presentationConfigOverrides: Data
    private let clipboardWriter: (String) -> Void
    private let topologyAuthorizationGate: TerminalBackendTopologyAuthorizationGate?
    private let externalMutationRouter: (any TerminalBackendExternalRuntimeMutationRouting)?
    private var baseRenderConfigRevision: UInt64
    private var baseRenderConfig: Data
    private var backendDefaultConfig = Data()
    private var resolvedConfigRevision: UInt64
    private var resolvedConfig: Data

    private var state = State.binding
    private(set) var snapshot = TerminalExternalRuntimeSnapshot(lifecycle: .unavailable)
    private var queue: TerminalBackendMutationQueue
    private var nextSequence: UInt64 = 1
    private var binding: TerminalBackendTerminalBinding?
    private var resolvedRequest: TerminalBackendTerminalRequest?
    private var bindingTask: Task<TerminalBackendTerminalBinding, any Error>?
    private var bindingTaskID: UUID?
    private var bindingTaskGeneration: UInt64?
    private var bindingReconcileRequested = true
    private var placementAdoptionTask: Task<Void, Never>?
    private var placementGeneration: UInt64 = 0
    private var drainTask: Task<Void, Never>?
    private var rendererEventTask: Task<Void, Never>?
    private var renderConfigTask: Task<Void, Never>?
    private var receiver: TerminalRenderFrameReceiver?
    private var receiveTask: Task<Void, Never>?
    private var receiveLoopControl: TerminalBackendFrameReceiveLoopControl?
    private var receiverRetirementTask: Task<Bool, Never>?
    private var receiverRetirementTaskID: UUID?
    // A fatal local Mach-drain failure cannot destroy the endpoint without
    // stranding a worker lease. This self-retention is a fail-closed last
    // resort and is cleared only by process teardown.
    private var unresolvedReceiverRetirements: [TerminalBackendReceiverRetirement] = []
    private var unresolvedReceiverRetirementOwner: PersistentTerminalExternalRuntime?
    private var accessibilityRefreshTask: Task<Void, Never>?
    private var accessibilityRefreshRequested = false
    private var accessibilityDemanded = false
    private let accessibilityFrameDemand = TerminalBackendAccessibilityFrameDemand()
    private let presentedFrameState = TerminalBackendPresentedFrameState()
    private var lastPresentedTerminalSequence: UInt64?
    private var accessibilityContinuations: [
        UUID: AsyncStream<TerminalAccessibilitySnapshot>.Continuation
    ] = [:]
    private var compositor: TerminalRenderCompositorView?
    private var mount: TerminalBackendPresentationMount?
    private var attachedPresentation: TerminalExternalPresentation?
    private var currentWorkspaceID: UUID
    private let diagnosticsWorkspaceContext: TerminalBackendRenderDiagnosticsWorkspaceContext
    private var currentViewport: TerminalExternalViewport?
    private var pendingViewportWithoutMetrics: TerminalExternalViewport?
    private var focused = false
    private var visible = false
    private var preedit: TerminalExternalPreedit?
    private var backendPresentationOpen = false
    private var rendererReconfigureNeeded = false
    private var detached = false
    private var canonicalCloseRequested = false
    private var detachAfterCanonicalClose = false

    init(
        client: any TerminalBackendClient,
        launchResolver: TerminalSurfaceLaunchResolver,
        launchRequest: TerminalSurfaceLaunchRequest,
        initialColumns: UInt16 = 80,
        initialRows: UInt16 = 24,
        presentationRegistry: TerminalBackendPresentationRegistry,
        renderConfigSource: TerminalBackendRenderConfigSource? = nil,
        presentationConfigOverrides: Data = Data(),
        resolvedConfigRevision: UInt64 = 0,
        resolvedConfig: Data = Data(),
        queueCapacity: Int = 256,
        topologyAuthorizationGate: TerminalBackendTopologyAuthorizationGate? = nil,
        externalMutationRouter: (any TerminalBackendExternalRuntimeMutationRouting)? = nil,
        launchResolution: (@MainActor (
            TerminalSurfaceLaunchRequest
        ) async -> TerminalSurfaceResolvedLaunch)? = nil,
        clipboardWriter: @escaping (String) -> Void = { text in
            GhosttyApp.terminalPasteboard.writeString(
                text,
                to: GHOSTTY_CLIPBOARD_STANDARD
            )
        }
    ) {
        self.client = client
        self.launchRequest = launchRequest
        self.resolveLaunch = launchResolution ?? { request in
            await launchResolver.resolveInstallingCommandShim(request)
        }
        self.initialColumns = initialColumns
        self.initialRows = initialRows
        self.presentationRegistry = presentationRegistry
        self.renderConfigSource = renderConfigSource
        self.presentationConfigOverrides = presentationConfigOverrides
        self.topologyAuthorizationGate = topologyAuthorizationGate
        self.externalMutationRouter = externalMutationRouter
        self.clipboardWriter = clipboardWriter
        if let current = renderConfigSource?.current {
            self.baseRenderConfigRevision = current.revision
            self.baseRenderConfig = current.data
            self.resolvedConfigRevision = max(1, current.revision)
            self.resolvedConfig = TerminalBackendRenderConfigSource.layered(
                base: current.data,
                presentationOverrides: presentationConfigOverrides
            )
        } else {
            self.baseRenderConfigRevision = 0
            self.baseRenderConfig = resolvedConfig
            self.resolvedConfigRevision = resolvedConfigRevision
            self.resolvedConfig = TerminalBackendRenderConfigSource.layered(
                base: resolvedConfig,
                presentationOverrides: presentationConfigOverrides
            )
        }
        self.currentWorkspaceID = launchRequest.workspaceID
        self.diagnosticsWorkspaceContext = TerminalBackendRenderDiagnosticsWorkspaceContext(
            launchRequest.workspaceID
        )
        self.queue = TerminalBackendMutationQueue(capacity: queueCapacity)
    }

    func attachPresentation(
        _ presentation: TerminalExternalPresentation
    ) -> any TerminalExternalPresentationLease {
        precondition(attachedPresentation == nil || attachedPresentation == presentation)
        attachedPresentation = presentation
        currentWorkspaceID = presentation.workspaceID
        diagnosticsWorkspaceContext.update(presentation.workspaceID)
        detached = false
        bindingReconcileRequested = binding == nil
        let mount = presentationRegistry.register(surfaceID: presentation.surfaceID)
        self.mount = mount
        mount.onHostMounted = { [weak self] in
            guard let self, self.visible else { return }
            self.rendererReconfigureNeeded = true
            self.scheduleDrain()
        }
        startRendererEventsIfNeeded()
        startRenderConfigEventsIfNeeded()
        scheduleDrain()
        return TerminalBackendPresentationLease { [weak self] in
            Task { @MainActor in
                self?.detachPresentation()
            }
        }
    }

    func adoptCanonicalPlacement(workspaceID: UUID) {
        attachedPresentation = attachedPresentation.map {
            TerminalExternalPresentation(
                surfaceID: $0.surfaceID,
                workspaceID: workspaceID
            )
        }
        guard currentWorkspaceID != workspaceID
                || binding.map({ $0.appWorkspaceID != workspaceID }) == true else { return }

        placementGeneration &+= 1
        let generation = placementGeneration
        // Presentation identity is a placement epoch. Late renderer events from
        // the prior workspace cannot attach to the replacement receiver.
        let previousPresentationID = presentationID
        presentationID = UUID()
        currentWorkspaceID = workspaceID
        diagnosticsWorkspaceContext.update(workspaceID)
        // A request resolved for the old placement contains old managed workspace
        // environment. Resolve it again before any not-yet-bound terminal is created.
        resolvedRequest = nil
        cancelBindingTask()
        let previousBinding = binding
        binding = nil
        bindingReconcileRequested = true
        backendPresentationOpen = false
        rendererReconfigureNeeded = visible
        state = .binding
        replaceSnapshot(
            lifecycle: .unavailable,
            accessibility: nil,
            accessibilityWasRead: true,
            clearCellMetrics: true
        )

        // Retire the old drawable generation synchronously. Stopping the XPC
        // receiver and detaching the daemon presentation may await, but no
        // queued prior-workspace frame can remain mounted after this call.
        let receiverRetirement = beginReceiverRotation()

        let previousAdoption = placementAdoptionTask
        let client = client
        placementAdoptionTask = Task { @MainActor [weak self] in
            _ = await previousAdoption?.value
            guard let self else { return }
            if let previousBinding {
                let quiesced = await awaitRendererPresentationQuiescence(
                    client: client,
                    presentationID: previousPresentationID,
                    binding: previousBinding
                )
                if !quiesced {
                    // Cancellation leaves the retired ingress active. It still
                    // rejects any late frame with an exact release.
                    if let receiverRetirement {
                        self.retainUnresolvedReceiverRetirement(receiverRetirement)
                    }
                    self.placementAdoptionTask = nil
                    self.markUnavailable()
                    return
                }
            }
            guard await self.finishReceiverRetirement(receiverRetirement) else {
                self.placementAdoptionTask = nil
                self.markUnavailable()
                return
            }
            guard !self.detached else { return }
            guard self.placementGeneration == generation, !self.detached else { return }
            self.placementAdoptionTask = nil
            self.scheduleDrain()
        }
    }

    func enqueue(
        _ mutation: TerminalExternalRuntimeMutation
    ) -> TerminalExternalIngressResult {
        switch state {
        case .processExited:
            return .rejected(.processExited)
        case .unavailable:
            return .rejected(.unavailable)
        case .binding, .live:
            break
        }
        guard !detached else { return .rejected(.unavailable) }
        if case .mouse = mutation,
           snapshot.cellMetrics == nil || !backendPresentationOpen {
            return .rejected(.unavailable)
        }
        let sequence = nextSequence
        guard queue.append(
            TerminalBackendQueuedMutation(
                sequence: sequence,
                requestID: UUID(),
                mutation: mutation
            )
        ) else {
            return .rejected(.queueFull)
        }
        if case .closeCanonicalTerminal = mutation {
            canonicalCloseRequested = true
        }
        nextSequence &+= 1
        scheduleDrain()
        return .accepted(sequence: sequence)
    }

    func readScreenText(_ request: TerminalExternalScreenTextRequest) async -> String? {
        switch state {
        case .processExited, .unavailable:
            return snapshot.visibleText
        case .binding, .live:
            break
        }
        do {
            let binding = try await ensureBinding()
            let text = try await client.readScreenText(request, from: binding)
            replaceSnapshot(visibleText: text)
            return text
        } catch {
            markUnavailable()
            return snapshot.visibleText
        }
    }

    func readSelection() async -> TerminalExternalSelection? {
        switch state {
        case .processExited, .unavailable:
            return snapshot.selection
        case .binding, .live:
            break
        }
        do {
            let binding = try await ensureBinding()
            let selection = try await client.readSelection(from: binding)
            replaceSnapshot(selection: selection, selectionWasRead: true)
            return selection
        } catch {
            markUnavailable()
            return snapshot.selection
        }
    }

    func enableAccessibility() {
        guard !detached else { return }
        accessibilityDemanded = true
        accessibilityFrameDemand.enable()
        lastPresentedTerminalSequence = currentPresentedTerminalSequence()
        requestAccessibilityRefresh()
    }

    func accessibilitySnapshots() -> AsyncStream<TerminalAccessibilitySnapshot> {
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            accessibilityContinuations[identifier] = continuation
            if let accessibility = snapshot.accessibility {
                continuation.yield(accessibility)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.accessibilityContinuations.removeValue(forKey: identifier)
                }
            }
        }
    }

    func activateAccessibilityLink(
        _ link: TerminalAccessibilityLink,
        snapshot requestedSnapshot: TerminalAccessibilitySnapshot
    ) async -> String? {
        guard !detached,
              snapshot.accessibility == requestedSnapshot,
              requestedSnapshot.links.contains(link) else { return nil }
        do {
            let binding = try await ensureBinding()
            return try await client.activateAccessibilityLink(
                link,
                snapshot: requestedSnapshot,
                from: binding
            )
        } catch {
            requestAccessibilityRefresh()
            return nil
        }
    }

    func activateHyperlink(
        at event: TerminalExternalMouseEvent
    ) async -> TerminalExternalHyperlinkHit? {
        guard !detached,
              let contentSequence = currentPresentedTerminalSequence() else { return nil }
        do {
            let binding = try await ensureBinding()
            return try await client.activateHyperlink(
                at: event,
                contentSequence: contentSequence,
                presentationID: presentationID,
                from: binding
            )
        } catch {
            return nil
        }
    }

    private func scheduleDrain() {
        guard !detached, drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer {
            drainTask = nil
            let canRetryQueuedMutation: Bool
            if case .unavailable = state {
                canRetryQueuedMutation = false
            } else {
                canRetryQueuedMutation = !queue.isEmpty
            }
            if !detached && (
                bindingReconcileRequested || canRetryQueuedMutation || rendererReconfigureNeeded
            ) {
                scheduleDrain()
            }
        }
        do {
            _ = try await ensureBinding()
            while !detached {
                if rendererReconfigureNeeded {
                    rendererReconfigureNeeded = false
                    try await reconcileRenderer()
                    continue
                }
                guard let queued = queue.first else { return }
                try await apply(queued)
                if queue.first?.requestID == queued.requestID {
                    queue.removeFirst()
                }
                if case .processExited = state { return }
            }
        } catch is CancellationError {
            return
        } catch {
            markUnavailable()
            if detachAfterCanonicalClose {
                canonicalCloseRequested = false
                detachPresentation()
            }
        }
    }

    private func ensureBinding() async throws -> TerminalBackendTerminalBinding {
        while let placementAdoptionTask {
            await placementAdoptionTask.value
        }
        while let receiverRetirementTask {
            guard await receiverRetirementTask.value else {
                throw TerminalBackendClientError.presentationUnavailable
            }
        }
        try Task.checkCancellation()
        guard !detached else { throw CancellationError() }
        if let binding {
            if case .unavailable = state {
                state = .live
                replaceSnapshot(lifecycle: .live)
            }
            bindingReconcileRequested = false
            return binding
        }
        if let bindingTask,
           bindingTaskGeneration == placementGeneration {
            return try await bindingTask.value
        }

        cancelBindingTask()
        let client = client
        let topologyAuthorizationGate = topologyAuthorizationGate
        let resolveLaunch = resolveLaunch
        let attemptID = UUID()
        let placementGeneration = self.placementGeneration
        let workspaceID = currentWorkspaceID
        let launchRequest = launchRequest.reparented(to: workspaceID)
        let cachedRequest = resolvedRequest.flatMap { request in
            request.appWorkspaceID == workspaceID ? request : nil
        }
        let presentationID = presentationID
        let task = Task<TerminalBackendTerminalBinding, any Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            let request: TerminalBackendTerminalRequest
            if let cachedRequest {
                request = cachedRequest
            } else {
                let launch = await resolveLaunch(launchRequest)
                try self.validateBindingAttempt(
                    id: attemptID,
                    generation: placementGeneration,
                    workspaceID: workspaceID
                )
                request = TerminalBackendTerminalRequest(
                    appWorkspaceID: workspaceID,
                    appSurfaceID: launchRequest.surfaceID,
                    workingDirectory: launch.workingDirectory,
                    command: launch.command,
                    arguments: launch.arguments,
                    environment: launch.environment,
                    initialInput: launch.initialInput,
                    waitAfterCommand: launch.waitAfterCommand,
                    columns: self.initialColumns,
                    rows: self.initialRows
                )
            }
            try self.validateBindingAttempt(
                id: attemptID,
                generation: placementGeneration,
                workspaceID: workspaceID
            )
            let placement = TerminalBackendTopologyPlacement(
                workspaceID: request.appWorkspaceID,
                surfaceID: request.appSurfaceID
            )
            while true {
                let admissionLease = try await topologyAuthorizationGate?
                    .waitUntilAuthorized(placement)
                try self.validateBindingAttempt(
                    id: attemptID,
                    generation: placementGeneration,
                    workspaceID: workspaceID
                )
                let binding = try await client.ensureTerminal(request)
                do {
                    try self.validateBindingAttempt(
                        id: attemptID,
                        generation: placementGeneration,
                        workspaceID: workspaceID,
                        binding: binding
                    )
                    if let topologyAuthorizationGate, let admissionLease {
                        try await topologyAuthorizationGate.validate(admissionLease)
                        try self.validateBindingAttempt(
                            id: attemptID,
                            generation: placementGeneration,
                            workspaceID: workspaceID,
                            binding: binding
                        )
                    }

                    let uxState = try await client.readTerminalUXState(from: binding)
                    try self.validateBindingAttempt(
                        id: attemptID,
                        generation: placementGeneration,
                        workspaceID: workspaceID,
                        binding: binding
                    )
                    if let topologyAuthorizationGate, let admissionLease {
                        try await topologyAuthorizationGate.validate(admissionLease)
                    }

                    // No suspension is allowed between this final local check
                    // and publishing the binding into the MainActor runtime.
                    try self.validateBindingAttempt(
                        id: attemptID,
                        generation: placementGeneration,
                        workspaceID: workspaceID,
                        binding: binding
                    )
                    self.resolvedRequest = request
                    self.binding = binding
                    self.currentWorkspaceID = binding.appWorkspaceID
                    self.diagnosticsWorkspaceContext.update(binding.appWorkspaceID)
                    self.state = .live
                    self.bindingReconcileRequested = false
                    self.replaceSnapshot(
                        lifecycle: .live,
                        copyModeActive: uxState.copyModeActive,
                        mouseTracking: uxState.mouseTracking,
                        copyCursor: uxState.copyCursor,
                        cursor: uxState.cursor,
                        terminalUXWasRead: uxState.terminalUXWasRead,
                        selection: uxState.selection,
                        selectionWasRead: uxState.selectionWasRead,
                        search: uxState.search,
                        viewportState: uxState.viewportState
                    )
                    self.requestAccessibilityRefresh()
                    self.clearBindingTask(ifCurrent: attemptID)
                    return binding
                } catch TerminalBackendTopologyAdmissionError.invalidated {
                    try? await client.detachPresentation(
                        presentationID: presentationID,
                        from: binding
                    )
                    try self.validateBindingAttempt(
                        id: attemptID,
                        generation: placementGeneration,
                        workspaceID: workspaceID
                    )
                    continue
                } catch {
                    try? await client.detachPresentation(
                        presentationID: presentationID,
                        from: binding
                    )
                    throw error
                }
            }
        }
        bindingTaskID = attemptID
        bindingTaskGeneration = placementGeneration
        bindingTask = task
        do {
            return try await task.value
        } catch {
            clearBindingTask(ifCurrent: attemptID)
            throw error
        }
    }

    private func validateBindingAttempt(
        id: UUID,
        generation: UInt64,
        workspaceID: UUID,
        binding: TerminalBackendTerminalBinding? = nil
    ) throws {
        try Task.checkCancellation()
        guard !detached,
              bindingTaskID == id,
              bindingTaskGeneration == generation,
              placementGeneration == generation,
              currentWorkspaceID == workspaceID,
              (binding?.appWorkspaceID ?? workspaceID) == workspaceID else {
            throw CancellationError()
        }
    }

    private func cancelBindingTask() {
        bindingTask?.cancel()
        bindingTask = nil
        bindingTaskID = nil
        bindingTaskGeneration = nil
    }

    private func clearBindingTask(ifCurrent id: UUID) {
        guard bindingTaskID == id else { return }
        bindingTask = nil
        bindingTaskID = nil
        bindingTaskGeneration = nil
    }

    private func apply(_ queued: TerminalBackendQueuedMutation) async throws {
        guard let binding else { throw TerminalBackendClientError.unavailable }
        let mutation = queued.mutation
        updatePresentationState(for: mutation)

        if shouldApplyLocallyOnly(mutation) {
            if case .visibility(false) = mutation {
                await stopRendererPresentation()
            }
            return
        }

        let descriptor = try presentationDescriptor(for: mutation, binding: binding)
        let outcome: TerminalBackendMutationOutcome
        if let externalMutationRouter {
            outcome = try await externalMutationRouter.apply(
                mutation,
                requestID: queued.requestID,
                client: client,
                binding: binding,
                presentation: descriptor
            )
        } else {
            outcome = try await client.apply(
                mutation,
                requestID: queued.requestID,
                to: binding,
                presentation: descriptor
            )
        }
        if let updatedBinding = outcome.binding {
            self.binding = updatedBinding
            currentWorkspaceID = updatedBinding.appWorkspaceID
            diagnosticsWorkspaceContext.update(updatedBinding.appWorkspaceID)
            resolvedRequest = resolvedRequest?.reparented(
                to: updatedBinding.appWorkspaceID
            )
        }
        replaceSnapshot(
            lifecycle: outcome.lifecycle,
            visibleText: outcome.visibleText,
            processMetadata: outcome.processMetadata,
            needsCloseConfirmation: outcome.needsCloseConfirmation,
            copyModeActive: outcome.copyModeActive,
            mouseTracking: outcome.mouseTracking,
            copyCursor: outcome.copyCursor,
            cursor: outcome.cursor,
            terminalUXWasRead: outcome.terminalUXWasRead,
            selection: outcome.selection,
            selectionWasRead: outcome.selectionWasRead,
            search: outcome.search,
            viewportState: outcome.viewportState
        )
        if let clipboardText = outcome.clipboardText, !clipboardText.isEmpty {
            clipboardWriter(clipboardText)
        }

        if let activation = outcome.rendererActivation {
            try await installRendererActivation(activation)
        }
        if let attachment = outcome.rendererAttachment {
            try await installRendererAttachment(attachment)
        }
        requestAccessibilityRefresh()
        switch mutation {
        case .visibility(true), .resize, .reparent:
            if descriptor != nil, visible {
                backendPresentationOpen = true
            }
        case .visibility(false):
            await stopRendererPresentation()
        case .closeCanonicalTerminal:
            state = .processExited
            queue.removeAll()
            await stopRendererPresentation()
            if detachAfterCanonicalClose {
                detachPresentation()
            }
        default:
            break
        }
    }

    private func updatePresentationState(for mutation: TerminalExternalRuntimeMutation) {
        switch mutation {
        case .focus(let focused):
            self.focused = focused
        case .visibility(let visible):
            self.visible = visible
        case .resize(let viewport):
            currentViewport = viewport
            if snapshot.cellMetrics == nil {
                pendingViewportWithoutMetrics = viewport
            }
        case .preedit(let preedit):
            self.preedit = preedit
        case .input, .mouse, .bindingAction, .selection, .copyMode, .search, .scroll,
             .reparent, .closeCanonicalTerminal:
            break
        }
    }

    private func shouldApplyLocallyOnly(_ mutation: TerminalExternalRuntimeMutation) -> Bool {
        switch mutation {
        case .visibility(true):
            return !canPresent
        case .visibility(false):
            return !backendPresentationOpen
        case .resize:
            return visible && !canPresent
        case .preedit:
            return !backendPresentationOpen
        default:
            return false
        }
    }

    private var canPresent: Bool {
        visible && mount?.isMounted == true && currentViewport != nil
    }

    private func presentationDescriptor(
        for mutation: TerminalExternalRuntimeMutation,
        binding: TerminalBackendTerminalBinding
    ) throws -> TerminalBackendPresentationDescriptor? {
        let needsDescriptor: Bool
        switch mutation {
        case .focus, .visibility, .resize, .preedit, .mouse, .reparent:
            needsDescriptor = backendPresentationOpen || canPresent
        case .input:
            needsDescriptor = backendPresentationOpen || canPresent
        case .bindingAction, .selection, .copyMode, .search, .scroll,
             .closeCanonicalTerminal:
            needsDescriptor = false
        }
        guard needsDescriptor, let viewport = currentViewport else { return nil }
        guard !resolvedConfig.isEmpty else {
            throw TerminalBackendClientError.presentationUnavailable
        }
        let receiver = try ensureReceiver(binding: binding, viewport: viewport)
        return TerminalBackendPresentationDescriptor(
            presentationID: presentationID,
            endpoint: receiver.endpoint,
            viewport: viewport,
            focused: focused,
            visible: visible,
            preedit: preedit,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            resolvedConfigRevision: resolvedConfigRevision,
            resolvedConfig: resolvedConfig
        )
    }

    private func ensureReceiver(
        binding: TerminalBackendTerminalBinding,
        viewport: TerminalExternalViewport
    ) throws -> TerminalRenderFrameReceiver {
        if let receiver { return receiver }
        guard let width = UInt32(exactly: viewport.widthPixels),
              let height = UInt32(exactly: viewport.heightPixels) else {
            throw TerminalBackendClientError.presentationUnavailable
        }
        let placeholder = try TerminalRenderPresentationFence(
            daemonInstanceID: binding.authority.daemonInstanceID.rawValue,
            rendererEpoch: 1,
            terminalID: binding.surfaceID.rawValue,
            terminalEpoch: 0,
            minimumTerminalSequence: 0,
            presentationID: presentationID,
            presentationGeneration: 1,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            completionRequirement: .producerCompleted
        )
        let receiver = try TerminalRenderFrameReceiver(initialFence: placeholder)
        self.receiver = receiver
        return receiver
    }

    private func reconcileRenderer() async throws {
        guard canPresent, let binding, let viewport = currentViewport else { return }
        guard !resolvedConfig.isEmpty else {
            throw TerminalBackendClientError.presentationUnavailable
        }
        let receiver = try ensureReceiver(binding: binding, viewport: viewport)
        let descriptor = TerminalBackendPresentationDescriptor(
            presentationID: presentationID,
            endpoint: receiver.endpoint,
            viewport: viewport,
            focused: focused,
            visible: visible,
            preedit: preedit,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            resolvedConfigRevision: resolvedConfigRevision,
            resolvedConfig: resolvedConfig
        )
        let outcome = try await client.apply(
            .visibility(true),
            requestID: UUID(),
            to: binding,
            presentation: descriptor
        )
        backendPresentationOpen = true
        state = .live
        replaceSnapshot(
            lifecycle: .live,
            visibleText: outcome.visibleText,
            processMetadata: outcome.processMetadata,
            needsCloseConfirmation: outcome.needsCloseConfirmation
        )
        if let activation = outcome.rendererActivation {
            try await installRendererActivation(activation)
        }
        if let attachment = outcome.rendererAttachment {
            try await installRendererAttachment(attachment)
        }
        requestAccessibilityRefresh()
    }

    private func installRendererAttachment(
        _ attachment: TerminalBackendRendererAttachment
    ) async throws {
        guard visible, let receiver else { return }
        try await receiver.authorize(worker: attachment.worker)
        await receiver.updateFence(attachment.fence)

        let compositor: TerminalRenderCompositorView
        if let existing = self.compositor {
            presentedFrameState.install(attachment.fence)
            lastPresentedTerminalSequence = nil
            existing.updateFence(attachment.fence)
            compositor = existing
        } else {
            let client = client
            let diagnostics = TerminalBackendRenderDiagnostics.shared
            let diagnosticsWorkspaceContext = diagnosticsWorkspaceContext
            let accessibilityFrameDemand = accessibilityFrameDemand
            let presentedFrameState = presentedFrameState
            presentedFrameState.install(attachment.fence)
            compositor = try TerminalRenderCompositorView(
                fence: attachment.fence,
                frameReleaseHandler: { release in
                    Task {
                        await returnRendererFrameLease(client: client, release: release)
                    }
                },
                frameDispositionHandler: { frame, result in
                    diagnostics.record(
                        workspaceID: diagnosticsWorkspaceContext.current(),
                        frame: frame,
                        result: result
                    )
                },
                framePresentedHandler: { [weak self] metadata in
                    presentedFrameState.record(metadata)
                    guard accessibilityFrameDemand.isEnabled else { return }
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.presentationID == metadata.presentationID,
                              self.compositor?.fence.rendererEpoch == metadata.rendererEpoch,
                              self.compositor?.fence.presentationGeneration
                                == metadata.presentationGeneration,
                              !self.detached else { return }
                        if self.lastPresentedTerminalSequence != metadata.terminalSequence {
                            self.lastPresentedTerminalSequence = metadata.terminalSequence
                            self.requestAccessibilityRefresh()
                        }
                    }
                }
            )
            self.compositor = compositor
        }
        mount?.install(compositor)
        replaceSnapshot(cellMetrics: attachment.cellMetrics)
        startReceivingFrames(receiver: receiver, ingress: compositor.frameIngress)
        coalesceViewportUsingExactMetrics(attachment.cellMetrics)
    }

    private func coalesceViewportUsingExactMetrics(
        _ metrics: TerminalExternalCellMetrics
    ) {
        guard let pending = pendingViewportWithoutMetrics ?? currentViewport,
              metrics.cellWidthPixels > 0,
              metrics.cellHeightPixels > 0 else { return }
        pendingViewportWithoutMetrics = nil
        let horizontalPadding = max(
            0,
            metrics.surfaceWidthPixels - metrics.columns * metrics.cellWidthPixels
        )
        let verticalPadding = max(
            0,
            metrics.surfaceHeightPixels - metrics.rows * metrics.cellHeightPixels
        )
        let columns = max(
            1,
            (pending.widthPixels - horizontalPadding) / metrics.cellWidthPixels
        )
        let rows = max(
            1,
            (pending.heightPixels - verticalPadding) / metrics.cellHeightPixels
        )
        guard pending.proposedColumns != columns || pending.proposedRows != rows else {
            return
        }
        currentViewport = TerminalExternalViewport(
            widthPoints: pending.widthPoints,
            heightPoints: pending.heightPoints,
            widthPixels: pending.widthPixels,
            heightPixels: pending.heightPixels,
            xScale: pending.xScale,
            yScale: pending.yScale,
            proposedColumns: columns,
            proposedRows: rows
        )
        rendererReconfigureNeeded = true
    }

    private func startReceivingFrames(
        receiver: TerminalRenderFrameReceiver,
        ingress: TerminalRenderCompositorIngress
    ) {
        guard receiveTask == nil else { return }
        let control = TerminalBackendFrameReceiveLoopControl()
        receiveLoopControl = control
        let client = client
        let failureHandler: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.detached, self.visible else { return }
                self.rendererReconfigureNeeded = true
                self.scheduleDrain()
            }
        }
        receiveTask = Task.detached { [receiver, ingress, control, client, failureHandler] in
            do {
                while !Task.isCancelled, !control.shouldStop {
                    switch try await receiver.receive(
                        timeoutMilliseconds: TerminalRenderFrameReceiver
                            .maximumReceiveTimeoutMilliseconds
                    ) {
                    case .frame(let frame):
                        if control.shouldStop {
                            await returnRendererFrameLease(
                                client: client,
                                release: TerminalRenderFrameRelease(frame: frame)
                            )
                        } else {
                            _ = await ingress.enqueue(frame)
                        }
                    case .dropped(_, let release):
                        if let release {
                            await returnRendererFrameLease(client: client, release: release)
                        }
                    case .timedOut:
                        continue
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                failureHandler()
            }
        }
    }

    private func startRendererEventsIfNeeded() {
        guard rendererEventTask == nil else { return }
        rendererEventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.detached {
                let events = await self.client.rendererEvents()
                for await event in events {
                    guard !Task.isCancelled, !self.detached else { return }
                    await self.handleRendererEvent(event)
                }
                guard !Task.isCancelled, !self.detached else { return }
                let presentationID = self.presentationID
                let binding = self.binding
                self.cancelBindingTask()
                self.binding = nil
                self.bindingReconcileRequested = true
                self.state = .binding
                if await self.rotateReceiverAfterDaemonQuiescence(
                    presentationID: presentationID,
                    binding: binding
                ) {
                    self.backendPresentationOpen = false
                    self.rendererReconfigureNeeded = true
                    self.scheduleDrain()
                } else {
                    self.markUnavailable()
                }
                await Task.yield()
            }
        }
    }

    private func startRenderConfigEventsIfNeeded() {
        guard renderConfigTask == nil, let renderConfigSource else { return }
        renderConfigTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let updates = renderConfigSource.updates()
            for await update in updates {
                guard !Task.isCancelled, !self.detached else { return }
                guard update.revision != self.baseRenderConfigRevision else { continue }
                await self.installBaseRenderConfig(update)
            }
        }
    }

    private func installBaseRenderConfig(
        _ update: TerminalBackendRenderConfigSnapshot
    ) async {
        baseRenderConfigRevision = update.revision
        baseRenderConfig = update.data
        resolvedConfigRevision &+= 1
        if resolvedConfigRevision == 0 { resolvedConfigRevision = 1 }
        resolvedConfig = TerminalBackendRenderConfigSource.layered(
            base: baseRenderConfig,
            backendDefaults: backendDefaultConfig,
            presentationOverrides: presentationConfigOverrides
        )
        guard canPresent else { return }
        if backendPresentationOpen {
            guard let binding, let viewport = currentViewport, let receiver else {
                rendererReconfigureNeeded = true
                return
            }
            let descriptor = TerminalBackendPresentationDescriptor(
                presentationID: presentationID,
                endpoint: receiver.endpoint,
                viewport: viewport,
                focused: focused,
                visible: false,
                preedit: preedit,
                pixelFormat: pixelFormat,
                colorSpace: colorSpace,
                resolvedConfigRevision: resolvedConfigRevision,
                resolvedConfig: resolvedConfig
            )
            do {
                _ = try await client.apply(
                    .visibility(false),
                    requestID: UUID(),
                    to: binding,
                    presentation: descriptor
                )
            } catch {
                // Keep receiving from the old endpoint. Destroying it without
                // the worker's quiescence acknowledgement would strand leases.
                return
            }
        }
        backendPresentationOpen = false
        await rotateReceiverAfterQuiescenceProof()
        rendererReconfigureNeeded = true
        scheduleDrain()
    }

    private func installRendererActivation(
        _ activation: TerminalBackendRendererActivation
    ) async throws {
        guard visible,
              activation.presentationID == presentationID,
              let receiver else { return }
        try await receiver.authorize(worker: activation.worker)
        await receiver.updateFence(activation.fence)
        try await client.activateRenderer(activation)
    }

    private func handleRendererEvent(_ event: TerminalBackendRendererEvent) async {
        switch event {
        case .workerChanged(let changed):
            guard changed.workspaceID.rawValue == currentWorkspaceID else { return }
            let presentedEpoch = compositor?.fence.rendererEpoch
            let oldWorkerDied = presentedEpoch == changed.priorRendererEpoch
                && (changed.rendererEpoch != presentedEpoch || changed.state != .ready)
            if oldWorkerDied {
                await rotateReceiverAfterQuiescenceProof()
                backendPresentationOpen = false
            }
            if changed.state == .ready {
                rendererReconfigureNeeded = true
                scheduleDrain()
            }
        case .presentationReady(let eventPresentationID, let attachment):
            guard eventPresentationID == presentationID,
                  attachment.fence.presentationID == presentationID else { return }
            do {
                try await installRendererAttachment(attachment)
            } catch {
                if await rotateReceiverAfterDaemonQuiescence(
                    presentationID: presentationID,
                    binding: binding
                ) {
                    backendPresentationOpen = false
                    rendererReconfigureNeeded = true
                    scheduleDrain()
                } else {
                    markUnavailable()
                }
            }
        case .connectionLost(let authority):
            guard let lostBinding = binding, lostBinding.authority == authority else { return }
            cancelBindingTask()
            binding = nil
            bindingReconcileRequested = true
            state = .binding
            replaceSnapshot(
                lifecycle: .unavailable,
                accessibility: nil,
                accessibilityWasRead: true,
                clearCellMetrics: true
            )
            if await rotateReceiverAfterDaemonQuiescence(
                presentationID: presentationID,
                binding: lostBinding
            ) {
                backendPresentationOpen = false
                scheduleDrain()
            } else {
                markUnavailable()
            }
        case .reconnected:
            rendererReconfigureNeeded = true
            scheduleDrain()
        }
    }

#if DEBUG
    func debugPresentationIDForTesting() -> UUID {
        presentationID
    }

    func debugFirstQueuedMutationRequestIDForTesting() -> UUID? {
        queue.first?.requestID
    }

    func debugIsUnavailableForTesting() -> Bool {
        if case .unavailable = state { return true }
        return false
    }

    func debugHasCurrentFrameReceiverForTesting() -> Bool {
        receiver != nil
    }

    func debugHasFrameReceiverRetirementForTesting() -> Bool {
        receiverRetirementTask != nil || !unresolvedReceiverRetirements.isEmpty
    }

    func debugHandleRendererEventForTesting(
        _ event: TerminalBackendRendererEvent
    ) async {
        await handleRendererEvent(event)
    }

    func debugInstallPresentedFrameForTesting(
        fence: TerminalRenderPresentationFence,
        metadata: TerminalRenderFrameMetadata
    ) {
        presentedFrameState.install(fence)
        presentedFrameState.record(metadata)
    }
#endif

    /// Retires an endpoint only when the caller already has synchronous proof
    /// that its worker stopped publishing, such as an exact remove receipt or
    /// an exact worker-lifetime death event.
    private func rotateReceiverAfterQuiescenceProof() async {
        if let receiverRetirementTask {
            guard await receiverRetirementTask.value else { return }
        }
        let retirement = beginReceiverRotation()
        _ = await finishReceiverRetirement(retirement)
    }

    /// Unmounts the current drawable immediately, then keeps its receive loop
    /// and endpoint alive until the daemon acknowledges the exact presentation
    /// removal across any intervening reconnect.
    private func rotateReceiverAfterDaemonQuiescence(
        presentationID: UUID,
        binding: TerminalBackendTerminalBinding?
    ) async -> Bool {
        let retirement = beginReceiverRotation()
        let previous = receiverRetirementTask
        let taskID = UUID()
        receiverRetirementTaskID = taskID
        let client = client
        let task = Task<Bool, Never> { @MainActor [self] in
            if let previous {
                guard await previous.value else {
                    if let retirement {
                        retainUnresolvedReceiverRetirement(retirement)
                    }
                    if receiverRetirementTaskID == taskID {
                        receiverRetirementTask = nil
                        receiverRetirementTaskID = nil
                    }
                    return false
                }
            }
            let quiesced = await awaitRendererPresentationQuiescence(
                client: client,
                presentationID: presentationID,
                binding: binding
            )
            let retired: Bool
            if quiesced {
                retired = await finishReceiverRetirement(retirement)
            } else {
                if let retirement {
                    retainUnresolvedReceiverRetirement(retirement)
                }
                retired = false
            }
            if receiverRetirementTaskID == taskID {
                receiverRetirementTask = nil
                receiverRetirementTaskID = nil
            }
            return quiesced && retired
        }
        receiverRetirementTask = task
        return await task.value
    }

    @discardableResult
    private func beginReceiverRotation() -> TerminalBackendReceiverRetirement? {
        let retirement = receiver.map {
            TerminalBackendReceiverRetirement(
                receiver: $0,
                receiveTask: receiveTask,
                receiveLoopControl: receiveLoopControl
            )
        }
        receiveTask = nil
        receiveLoopControl = nil
        presentedFrameState.reset()
        lastPresentedTerminalSequence = nil
        receiver = nil
        compositor?.retire()
        compositor?.removeFromSuperview()
        compositor = nil
        mount?.removeCompositor()
        replaceSnapshot(clearCellMetrics: true)
        return retirement
    }

    /// Completes teardown only after the caller has proved that the worker can
    /// no longer publish to this endpoint (or the worker/session has died).
    private func finishReceiverRetirement(
        _ retirement: TerminalBackendReceiverRetirement?
    ) async -> Bool {
        guard let retirement else { return true }
        retirement.receiveLoopControl?.requestStop()
        await retirement.receiveTask?.value
        do {
            let releases = try await retirement.receiver.drainQuiescedFrames()
            for release in releases {
                guard await returnRendererFrameLease(client: client, release: release) else {
                    retainUnresolvedReceiverRetirement(retirement)
                    return false
                }
            }
        } catch TerminalRenderFrameTransportError.stopped {
            // A concurrent terminal session teardown already destroyed it.
        } catch {
            retainUnresolvedReceiverRetirement(retirement)
            return false
        }
        await retirement.receiver.stop()
        return true
    }

    private func retainUnresolvedReceiverRetirement(
        _ retirement: TerminalBackendReceiverRetirement
    ) {
        unresolvedReceiverRetirements.append(retirement)
        unresolvedReceiverRetirementOwner = self
    }

    private func stopRendererPresentation() async {
        backendPresentationOpen = false
        await rotateReceiverAfterQuiescenceProof()
    }

    private func detachPresentation() {
        guard !detached else { return }
        if canonicalCloseRequested {
            if case .processExited = state {
                // The close has crossed the daemon boundary; normal detach may finish.
            } else {
                detachAfterCanonicalClose = true
                scheduleDrain()
                return
            }
        }
        detached = true
        bindingReconcileRequested = false
        drainTask?.cancel()
        drainTask = nil
        cancelBindingTask()
        let pendingAdoption = placementAdoptionTask
        placementAdoptionTask = nil
        rendererEventTask?.cancel()
        rendererEventTask = nil
        renderConfigTask?.cancel()
        renderConfigTask = nil
        accessibilityRefreshTask?.cancel()
        accessibilityRefreshTask = nil
        accessibilityRefreshRequested = false
        accessibilityFrameDemand.disable()
        for continuation in accessibilityContinuations.values {
            continuation.finish()
        }
        accessibilityContinuations.removeAll()
        let receiverRetirement = beginReceiverRotation()
        if let mount {
            presentationRegistry.unregister(mount)
        }
        mount = nil
        let client = client
        let presentationID = presentationID
        let binding = binding
        let previousRetirement = receiverRetirementTask
        let taskID = UUID()
        receiverRetirementTaskID = taskID
        receiverRetirementTask = Task<Bool, Never> { @MainActor [self] in
            _ = await pendingAdoption?.value
            if let previousRetirement {
                _ = await previousRetirement.value
            }
            let quiesced = await awaitRendererPresentationQuiescence(
                client: client,
                presentationID: presentationID,
                binding: binding
            )
            let retired: Bool
            if quiesced {
                retired = await self.finishReceiverRetirement(receiverRetirement)
            } else {
                if let receiverRetirement {
                    self.retainUnresolvedReceiverRetirement(receiverRetirement)
                }
                retired = false
            }
            if receiverRetirementTaskID == taskID {
                receiverRetirementTask = nil
                receiverRetirementTaskID = nil
            }
            return quiesced && retired
        }
    }

    private func markUnavailable() {
        state = .unavailable
        bindingReconcileRequested = false
        replaceSnapshot(
            lifecycle: .unavailable,
            accessibility: nil,
            accessibilityWasRead: true
        )
    }

    private func requestAccessibilityRefresh() {
        guard accessibilityDemanded,
              !detached,
              lastPresentedTerminalSequence != nil else { return }
        if accessibilityRefreshTask != nil {
            accessibilityRefreshRequested = true
            return
        }
        accessibilityRefreshRequested = false
        accessibilityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.accessibilityRefreshTask = nil
                if self.accessibilityRefreshRequested {
                    self.requestAccessibilityRefresh()
                }
            }
            repeat {
                self.accessibilityRefreshRequested = false
                do {
                    guard let expectedContentSequence = self.lastPresentedTerminalSequence else {
                        return
                    }
                    let binding = try await self.ensureBinding()
                    let next = try await self.client.readAccessibilitySnapshot(
                        presentationID: self.presentationID,
                        expectedContentSequence: expectedContentSequence,
                        from: binding
                    )
                    guard !Task.isCancelled,
                          !self.detached,
                          self.lastPresentedTerminalSequence == expectedContentSequence,
                          next.surfaceID == binding.appSurfaceID,
                          next.presentationID == self.presentationID,
                          next.contentSequence == expectedContentSequence else {
                        self.accessibilityRefreshRequested = true
                        continue
                    }
                    self.installAccessibilitySnapshot(next)
                } catch is CancellationError {
                    return
                } catch {
                    // Accessibility is an optional semantic read path. The
                    // connection supervisor owns backend availability; a
                    // failed AX read must not kill a live PTY presentation.
                }
            } while self.accessibilityRefreshRequested && !Task.isCancelled
        }
    }

    private func currentPresentedTerminalSequence() -> UInt64? {
        presentedFrameState.latest()?.terminalSequence
    }

    private func installAccessibilitySnapshot(_ next: TerminalAccessibilitySnapshot) {
        let previous = snapshot.accessibility
        let sameRevision = previous.map {
            $0.presentationID == next.presentationID
                && $0.presentationGeneration == next.presentationGeneration
                && $0.terminalRevision == next.terminalRevision
                && $0.contentRevision == next.contentRevision
                && $0.viewportRevision == next.viewportRevision
        } ?? false
        guard !sameRevision else { return }
        replaceSnapshot(accessibility: next, accessibilityWasRead: true)
        for continuation in accessibilityContinuations.values {
            continuation.yield(next)
        }
    }

    private func replaceSnapshot(
        lifecycle: TerminalExternalRuntimeLifecycle? = nil,
        visibleText: String? = nil,
        cellMetrics: TerminalExternalCellMetrics? = nil,
        processMetadata: TerminalExternalProcessMetadata? = nil,
        needsCloseConfirmation: Bool? = nil,
        copyModeActive: Bool? = nil,
        mouseTracking: Bool? = nil,
        copyCursor: TerminalExternalCellPoint? = nil,
        cursor: TerminalExternalCursorState? = nil,
        terminalUXWasRead: Bool = false,
        selection: TerminalExternalSelection? = nil,
        selectionWasRead: Bool = false,
        search: TerminalExternalSearchState? = nil,
        viewportState: TerminalExternalViewportState? = nil,
        accessibility: TerminalAccessibilitySnapshot? = nil,
        accessibilityWasRead: Bool = false,
        clearCellMetrics: Bool = false
    ) {
        snapshot = TerminalExternalRuntimeSnapshot(
            lifecycle: lifecycle ?? snapshot.lifecycle,
            visibleText: visibleText ?? snapshot.visibleText,
            cellMetrics: clearCellMetrics ? nil : (cellMetrics ?? snapshot.cellMetrics),
            processMetadata: processMetadata ?? snapshot.processMetadata,
            needsCloseConfirmation: needsCloseConfirmation ?? snapshot.needsCloseConfirmation,
            copyModeActive: copyModeActive ?? snapshot.copyModeActive,
            mouseTracking: mouseTracking ?? snapshot.mouseTracking,
            copyCursor: terminalUXWasRead ? copyCursor : snapshot.copyCursor,
            cursor: terminalUXWasRead ? cursor : snapshot.cursor,
            selection: selectionWasRead ? selection : snapshot.selection,
            search: search ?? snapshot.search,
            viewportState: viewportState ?? snapshot.viewportState,
            accessibility: accessibilityWasRead ? accessibility : snapshot.accessibility
        )
    }
}

private extension TerminalSurfaceLaunchRequest {
    func reparented(to workspaceID: UUID) -> Self {
        Self(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            configTemplate: configTemplate,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: initialCommand,
            initialInput: initialInput,
            runtimeInitialInput: runtimeInitialInput,
            initialEnvironmentOverrides: initialEnvironmentOverrides,
            additionalEnvironment: additionalEnvironment
        )
    }
}
