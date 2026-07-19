import CmuxTerminal
import CmuxTerminalBackend
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
    let compositorIngress: TerminalRenderCompositorIngress?
    let releaseMetricsBeforeRetirement: TerminalBackendFrameReleaseLaneMetrics
}

enum TerminalBackendFrameReleasePriority: Sendable {
    case normal
    case recovery
}

enum TerminalBackendFrameReleaseEnqueueResult: Equatable, Sendable {
    case accepted
    case capacityExceeded
    case stopped
}

enum TerminalBackendFrameReleaseFailure: Equatable, Sendable {
    case capacityExceeded
    case sendFailed
    case stopped
}

struct TerminalBackendFrameReleaseLaneMetrics: Equatable, Sendable {
    var workerStarts: UInt64 = 0
    var sent: UInt64 = 0
    var outstanding = 0
    var maximumOutstanding = 0
    var capacityFailures: UInt64 = 0
    var sendFailures: UInt64 = 0
    var rejectedAfterStop: UInt64 = 0
}

/// One bounded FIFO for full-app IOSurface release acknowledgements.
/// GPU callbacks enqueue synchronously; one lifetime task performs every RPC.
final class TerminalBackendFrameReleaseLane: @unchecked Sendable {
    typealias Sender = @Sendable (TerminalRenderFrameRelease) async -> Bool
    typealias FailureHandler = @Sendable (TerminalBackendFrameReleaseFailure) -> Void

    private struct Entry: Sendable {
        let release: TerminalRenderFrameRelease
        let priority: TerminalBackendFrameReleasePriority
    }

    private struct State {
        var queue: TerminalBackendFrameReleaseRing<Entry>
        var accepting = true
        var normalOutstanding = 0
        var recoveryOutstanding = 0
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
        var metrics = TerminalBackendFrameReleaseLaneMetrics(workerStarts: 1)
    }

    private final class Core: @unchecked Sendable {
        let lock = NSLock()
        let normalCapacity: Int
        let recoveryCapacity: Int
        let signal: AsyncStream<Void>.Continuation
        let sender: Sender
        let onFailure: FailureHandler
        var state: State

        init(
            normalCapacity: Int,
            recoveryCapacity: Int,
            signal: AsyncStream<Void>.Continuation,
            sender: @escaping Sender,
            onFailure: @escaping FailureHandler
        ) {
            self.normalCapacity = normalCapacity
            self.recoveryCapacity = recoveryCapacity
            self.signal = signal
            self.sender = sender
            self.onFailure = onFailure
            state = State(queue: TerminalBackendFrameReleaseRing(
                capacity: normalCapacity + recoveryCapacity
            ))
        }

        func enqueue(
            _ release: TerminalRenderFrameRelease,
            priority: TerminalBackendFrameReleasePriority
        ) -> TerminalBackendFrameReleaseEnqueueResult {
            let result: TerminalBackendFrameReleaseEnqueueResult
            var shouldSignal = false
            var failure: TerminalBackendFrameReleaseFailure?
            lock.lock()
            if !state.accepting {
                state.metrics.rejectedAfterStop += 1
                result = .stopped
            } else if !hasCapacity(priority) {
                state.metrics.capacityFailures += 1
                result = .capacityExceeded
                failure = .capacityExceeded
            } else if !state.queue.append(Entry(
                release: release,
                priority: priority
            )) {
                state.metrics.capacityFailures += 1
                result = .capacityExceeded
                failure = .capacityExceeded
            } else {
                switch priority {
                case .normal: state.normalOutstanding += 1
                case .recovery: state.recoveryOutstanding += 1
                }
                state.metrics.outstanding += 1
                state.metrics.maximumOutstanding = max(
                    state.metrics.maximumOutstanding,
                    state.metrics.outstanding
                )
                result = .accepted
                shouldSignal = true
            }
            lock.unlock()
            if let failure { onFailure(failure) }
            if shouldSignal { signal.yield() }
            return result
        }

        func requestStop() {
            lock.lock()
            let shouldFinish = state.accepting
            state.accepting = false
            lock.unlock()
            if shouldFinish { signal.finish() }
        }

        func run(_ signals: AsyncStream<Void>) async {
            for await _ in signals { await drain() }
            await drain()
        }

        func waitUntilIdle() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if state.metrics.outstanding == 0 {
                    lock.unlock()
                    continuation.resume()
                } else {
                    state.idleWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func metrics() -> TerminalBackendFrameReleaseLaneMetrics {
            lock.lock()
            defer { lock.unlock() }
            return state.metrics
        }

        private func drain() async {
            while let entry = popFirst() {
                let sent = await sender(entry.release)
                complete(entry, sent: sent)
            }
        }

        private func popFirst() -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            return state.queue.popFirst()
        }

        private func complete(_ entry: Entry, sent: Bool) {
            var waiters: [CheckedContinuation<Void, Never>] = []
            lock.lock()
            switch entry.priority {
            case .normal: state.normalOutstanding -= 1
            case .recovery: state.recoveryOutstanding -= 1
            }
            state.metrics.outstanding -= 1
            if sent {
                state.metrics.sent += 1
            } else {
                state.metrics.sendFailures += 1
            }
            if state.metrics.outstanding == 0 {
                waiters = state.idleWaiters
                state.idleWaiters.removeAll(keepingCapacity: true)
            }
            lock.unlock()
            if !sent { onFailure(.sendFailed) }
            for waiter in waiters { waiter.resume() }
        }

        private func hasCapacity(
            _ priority: TerminalBackendFrameReleasePriority
        ) -> Bool {
            switch priority {
            case .normal: state.normalOutstanding < normalCapacity
            case .recovery: state.recoveryOutstanding < recoveryCapacity
            }
        }
    }

    private let core: Core
    private let worker: Task<Void, Never>

    init(
        normalCapacity: Int,
        recoveryCapacity: Int,
        send: @escaping Sender,
        onFailure: @escaping FailureHandler = { _ in }
    ) {
        precondition(normalCapacity > 0)
        precondition(recoveryCapacity > 0)
        let signals = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let core = Core(
            normalCapacity: normalCapacity,
            recoveryCapacity: recoveryCapacity,
            signal: signals.continuation,
            sender: send,
            onFailure: onFailure
        )
        self.core = core
        worker = Task.detached(priority: .utility) {
            await core.run(signals.stream)
        }
    }

    deinit { core.requestStop() }

    func enqueue(
        _ release: TerminalRenderFrameRelease,
        priority: TerminalBackendFrameReleasePriority
    ) -> TerminalBackendFrameReleaseEnqueueResult {
        core.enqueue(release, priority: priority)
    }

    func metrics() -> TerminalBackendFrameReleaseLaneMetrics { core.metrics() }

    func waitUntilIdle() async { await core.waitUntilIdle() }

    func stop() async {
        core.requestStop()
        await worker.value
    }
}

private struct TerminalBackendFrameReleaseRing<Element> {
    private var storage: [Element?]
    private var head = 0
    private var tail = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ value: Element) -> Bool {
        guard count < storage.count else { return false }
        storage[tail] = value
        tail = (tail + 1) % storage.count
        count += 1
        return true
    }

    mutating func popFirst() -> Element? {
        guard count > 0 else { return nil }
        let value = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return value
    }
}

/// Retries one renderer operation only when the ordered renderer lifecycle
/// advances. Subscribing before the first attempt closes the disconnect race:
/// a reconnect that overlaps a failed RPC is buffered and wakes the retry.
func retryRendererOperationOnLifecycleChange(
    eventRouter: TerminalBackendFrontendEventRouter,
    lifecycleKey: TerminalBackendRendererLifecycleKey,
    operation: @escaping @Sendable () async throws -> Void
) async -> Bool {
    while !Task.isCancelled {
        guard let checkpoint = await eventRouter.lifecycleCheckpoint() else {
            return false
        }
        do {
            try await operation()
            return true
        } catch {
            guard isTransientRendererOperationFailure(error) else { return false }
            guard await eventRouter.waitForLifecycleChange(
                after: checkpoint,
                key: lifecycleKey
            ) else { return false }
        }
    }
    return false
}

private func isTransientRendererOperationFailure(_ error: any Error) -> Bool {
    if error is CancellationError { return false }
    guard let protocolError = error as? BackendProtocolError else { return false }
    switch protocolError {
    case .notConnected, .connectionClosed:
        return true
    case .alreadyConnected, .requestIDExhausted, .malformedMessage, .oversizedMessage,
         .writeQueueOverflow, .peerIdentityMismatch, .server, .eventBufferOverflow,
         .invalidTopology, .incompatibleProtocol, .missingCapabilities,
         .unexpectedApplication, .mutationUnavailableInReadOnlyMode:
        return false
    @unknown default:
        return false
    }
}

private func rendererEventRouter(
    for client: any TerminalBackendClient,
    preferred: TerminalBackendFrontendEventRouter?
) async -> TerminalBackendFrontendEventRouter {
    if let preferred { return preferred }
    return await MainActor.run {
        TerminalBackendFrontendEventRouterRegistry.shared.router(
            for: client,
            configSource: nil
        )
    }
}

/// Retries the canonical detach until cmuxd proves worker quiescence. The
/// caller keeps its retired ingress active during this wait, so a reconnecting
/// worker cannot strand a frame lease in a destroyed endpoint.
func awaitRendererPresentationQuiescence(
    client: any TerminalBackendClient,
    presentationID: UUID,
    binding: TerminalBackendTerminalBinding?,
    eventRouter preferredEventRouter: TerminalBackendFrontendEventRouter? = nil
) async -> Bool {
    let eventRouter = await rendererEventRouter(
        for: client,
        preferred: preferredEventRouter
    )
    let lifecycleKey = binding.map {
        TerminalBackendRendererLifecycleKey.workspace($0.appWorkspaceID)
    } ?? .any
    return await retryRendererOperationOnLifecycleChange(
        eventRouter: eventRouter,
        lifecycleKey: lifecycleKey
    ) {
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
    release: TerminalRenderFrameRelease,
    eventRouter preferredEventRouter: TerminalBackendFrontendEventRouter? = nil
) async -> Bool {
    let eventRouter = await rendererEventRouter(
        for: client,
        preferred: preferredEventRouter
    )
    return await retryRendererOperationOnLifecycleChange(
        eventRouter: eventRouter,
        lifecycleKey: .rendererEpoch(release.metadata.rendererEpoch)
    ) {
        try await client.releaseFrame(release)
    }
}

func returnRendererFrameLease(
    client: any TerminalBackendClient,
    release: TerminalRenderFrameRelease,
    eventRouter: TerminalBackendFrontendEventRouter,
    deadline: Duration
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await returnRendererFrameLease(
                client: client,
                release: release,
                eventRouter: eventRouter
            )
        }
        group.addTask {
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return false
            }
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
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
    private static let normalFrameReleaseCapacity = 128
    private static let recoveryFrameReleaseCapacity = 16
    nonisolated private static let frameReleaseDeadline: Duration = .seconds(2)

    private enum State {
        case binding
        case live
        case processExited
        case unavailable
    }

    private struct RendererStateFence: Equatable {
        let operationGeneration: UInt64
        let placementGeneration: UInt64
        let presentationID: UUID
        let receiverIdentity: ObjectIdentifier?
    }

    private struct RendererStateOperationWaiter {
        let identifier: UUID
        let continuation: CheckedContinuation<Bool, Never>
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
    private let frontendEventRouter: TerminalBackendFrontendEventRouter
    private let frameReleaseLane: TerminalBackendFrameReleaseLane
    private let frameReleaseFailureContinuation:
        AsyncStream<TerminalBackendFrameReleaseFailure>.Continuation
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
    private var frontendEventRoute: TerminalBackendFrontendEventRoute?
    private var frontendEventRegistrationTask: Task<Void, Never>?
    private var frontendEventRegistrationGeneration = UUID()
    private var frameReleaseFailureTask: Task<Void, Never>?
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
    private var rendererStateOperationGeneration: UInt64 = 1
    private var rendererStateOperationLocked = false
    private var rendererStateOperationWaiters: [RendererStateOperationWaiter] = []
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
        let frontendEventRouter = TerminalBackendFrontendEventRouterRegistry.shared.router(
            for: client,
            configSource: renderConfigSource
        )
        self.frontendEventRouter = frontendEventRouter
        let frameReleaseFailures = AsyncStream<
            TerminalBackendFrameReleaseFailure
        >.makeStream(bufferingPolicy: .bufferingNewest(1))
        frameReleaseFailureContinuation = frameReleaseFailures.continuation
        frameReleaseLane = TerminalBackendFrameReleaseLane(
            normalCapacity: Self.normalFrameReleaseCapacity,
            recoveryCapacity: Self.recoveryFrameReleaseCapacity,
            send: { release in
                await returnRendererFrameLease(
                    client: client,
                    release: release,
                    eventRouter: frontendEventRouter,
                    deadline: Self.frameReleaseDeadline
                )
            },
            onFailure: { failure in
                frameReleaseFailures.continuation.yield(failure)
            }
        )
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
        frameReleaseFailureTask = Task {
            [weak self, failures = frameReleaseFailures.stream] in
            for await failure in failures {
                guard let self else { return }
                await self.handleFrameReleaseFailure(failure)
            }
        }
    }

    deinit {
        frameReleaseFailureContinuation.finish()
        frameReleaseFailureTask?.cancel()
    }

    func attachPresentation(
        _ presentation: TerminalExternalPresentation
    ) -> any TerminalExternalPresentationLease {
        precondition(attachedPresentation == nil || attachedPresentation == presentation)
        invalidateRendererStateOperations()
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
        refreshFrontendEventRoute()
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
        invalidateRendererStateOperations()
        let generation = placementGeneration
        let operationGeneration = rendererStateOperationGeneration
        // Presentation identity is a placement epoch. Late renderer events from
        // the prior workspace cannot attach to the replacement receiver.
        deactivateFrontendEventRoute()
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
                    binding: previousBinding,
                    eventRouter: self.frontendEventRouter
                )
                if !quiesced {
                    // Cancellation leaves the retired ingress active. It still
                    // rejects any late frame with an exact release.
                    if let receiverRetirement {
                        self.retainUnresolvedReceiverRetirement(receiverRetirement)
                    }
                    if self.placementGeneration == generation {
                        self.placementAdoptionTask = nil
                        if self.rendererStateOperationGeneration == operationGeneration,
                           !self.detached {
                            self.markUnavailable()
                        }
                    }
                    return
                }
            }
            guard await self.finishReceiverRetirement(receiverRetirement) else {
                if self.placementGeneration == generation {
                    self.placementAdoptionTask = nil
                    if self.rendererStateOperationGeneration == operationGeneration,
                       !self.detached {
                        self.markUnavailable()
                    }
                }
                return
            }
            guard self.placementGeneration == generation else { return }
            self.placementAdoptionTask = nil
            guard self.rendererStateOperationGeneration == operationGeneration,
                  !self.detached else { return }
            self.refreshFrontendEventRoute()
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

    private func invalidateRendererStateOperations() {
        rendererStateOperationGeneration &+= 1
        if rendererStateOperationGeneration == 0 {
            rendererStateOperationGeneration = 1
        }
    }

    private func rendererStateFence() -> RendererStateFence {
        RendererStateFence(
            operationGeneration: rendererStateOperationGeneration,
            placementGeneration: placementGeneration,
            presentationID: presentationID,
            receiverIdentity: receiver.map(ObjectIdentifier.init)
        )
    }

    private func rendererStateIsCurrent(
        _ fence: RendererStateFence,
        requireAttached: Bool = true
    ) -> Bool {
        rendererStateGenerationIsCurrent(fence, requireAttached: requireAttached)
            && fence.receiverIdentity == receiver.map(ObjectIdentifier.init)
    }

    private func rendererStateGenerationIsCurrent(
        _ fence: RendererStateFence,
        requireAttached: Bool = true
    ) -> Bool {
        fence.operationGeneration == rendererStateOperationGeneration
            && fence.placementGeneration == placementGeneration
            && fence.presentationID == presentationID
            && (!requireAttached || (!detached && attachedPresentation != nil))
    }

    private func acquireRendererStateOperation() async -> Bool {
        if !rendererStateOperationLocked {
            guard !Task.isCancelled else { return false }
            rendererStateOperationLocked = true
            return true
        }
        let identifier = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    rendererStateOperationWaiters.append(RendererStateOperationWaiter(
                        identifier: identifier,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRendererStateOperationWaiter(identifier)
            }
        }
    }

    private func cancelRendererStateOperationWaiter(_ identifier: UUID) {
        guard let index = rendererStateOperationWaiters.firstIndex(where: {
            $0.identifier == identifier
        }) else { return }
        rendererStateOperationWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func releaseRendererStateOperation() {
        if !rendererStateOperationWaiters.isEmpty {
            let waiter = rendererStateOperationWaiters.removeFirst()
            waiter.continuation.resume(returning: true)
        } else {
            rendererStateOperationLocked = false
        }
    }

    private func withRendererStateOperation<Result>(
        _ operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        guard await acquireRendererStateOperation() else { throw CancellationError() }
        defer { releaseRendererStateOperation() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func scheduleDrain() {
        guard !detached, drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        let startingPlacementGeneration = placementGeneration
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
            guard !Task.isCancelled,
                  !detached,
                  placementGeneration == startingPlacementGeneration else { return }
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
        try await withRendererStateOperation {
            try await self.applyRendererStateSerialized(queued)
        }
    }

    private func applyRendererStateSerialized(
        _ queued: TerminalBackendQueuedMutation
    ) async throws {
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
        let operationFence = rendererStateFence()
        let outcome: TerminalBackendMutationOutcome
        do {
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
        } catch {
            guard rendererStateIsCurrent(operationFence) else {
                throw CancellationError()
            }
            throw error
        }
        guard rendererStateIsCurrent(operationFence) else { throw CancellationError() }
        if let updatedBinding = outcome.binding {
            self.binding = updatedBinding
            let priorWorkspaceID = currentWorkspaceID
            currentWorkspaceID = updatedBinding.appWorkspaceID
            diagnosticsWorkspaceContext.update(updatedBinding.appWorkspaceID)
            resolvedRequest = resolvedRequest?.reparented(
                to: updatedBinding.appWorkspaceID
            )
            attachedPresentation = attachedPresentation.map {
                TerminalExternalPresentation(
                    surfaceID: $0.surfaceID,
                    workspaceID: updatedBinding.appWorkspaceID
                )
            }
            if priorWorkspaceID != updatedBinding.appWorkspaceID {
                await reindexFrontendEventRoute(
                    workspaceID: updatedBinding.appWorkspaceID
                )
                guard rendererStateIsCurrent(operationFence) else {
                    throw CancellationError()
                }
            }
        }
        guard rendererStateIsCurrent(operationFence) else { throw CancellationError() }
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

        do {
            if let activation = outcome.rendererActivation {
                try await installRendererActivation(activation)
            }
            if let attachment = outcome.rendererAttachment {
                try await installRendererAttachment(attachment)
            }
        } catch {
            guard rendererStateIsCurrent(operationFence) else {
                throw CancellationError()
            }
            throw error
        }
        guard rendererStateIsCurrent(operationFence) else { throw CancellationError() }
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
            if self.visible != visible {
                invalidateRendererStateOperations()
            }
            self.visible = visible
            refreshFrontendEventRoute()
        case .resize(let viewport):
            currentViewport = viewport
            if snapshot.cellMetrics == nil {
                pendingViewportWithoutMetrics = viewport
            }
        case .preedit(let preedit):
            self.preedit = preedit
        case .reparent, .closeCanonicalTerminal:
            invalidateRendererStateOperations()
        case .input, .mouse, .bindingAction, .selection, .copyMode, .search, .scroll:
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
        try await withRendererStateOperation {
            try await self.reconcileRendererStateSerialized()
        }
    }

    private func reconcileRendererStateSerialized() async throws {
        guard canPresent else { return }
        refreshFrontendEventRoute()
        await frontendEventRegistrationTask?.value
        guard frontendEventRoute != nil else {
            throw TerminalBackendClientError.presentationUnavailable
        }
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
        let operationFence = rendererStateFence()
        let outcome: TerminalBackendMutationOutcome
        do {
            outcome = try await client.apply(
                .visibility(true),
                requestID: UUID(),
                to: binding,
                presentation: descriptor
            )
        } catch {
            guard rendererStateIsCurrent(operationFence) else {
                throw CancellationError()
            }
            throw error
        }
        guard rendererStateIsCurrent(operationFence), canPresent else {
            throw CancellationError()
        }
        backendPresentationOpen = true
        state = .live
        replaceSnapshot(
            lifecycle: .live,
            visibleText: outcome.visibleText,
            processMetadata: outcome.processMetadata,
            needsCloseConfirmation: outcome.needsCloseConfirmation
        )
        do {
            if let activation = outcome.rendererActivation {
                try await installRendererActivation(activation)
            }
            if let attachment = outcome.rendererAttachment {
                try await installRendererAttachment(attachment)
            }
        } catch {
            guard rendererStateIsCurrent(operationFence) else {
                throw CancellationError()
            }
            throw error
        }
        guard rendererStateIsCurrent(operationFence), canPresent else {
            throw CancellationError()
        }
        requestAccessibilityRefresh()
    }

    private func installRendererAttachment(
        _ attachment: TerminalBackendRendererAttachment
    ) async throws {
        guard !detached,
              visible,
              attachment.fence.presentationID == presentationID,
              let receiver else { return }
        let operationFence = rendererStateFence()
        do {
            try await receiver.authorize(worker: attachment.worker)
        } catch {
            guard rendererStateIsCurrent(operationFence), self.receiver === receiver else {
                throw CancellationError()
            }
            throw error
        }
        guard rendererStateIsCurrent(operationFence), self.receiver === receiver else {
            throw CancellationError()
        }
        await receiver.updateFence(attachment.fence)
        guard rendererStateIsCurrent(operationFence), self.receiver === receiver else {
            throw CancellationError()
        }

        let compositor: TerminalRenderCompositorView
        if let existing = self.compositor {
            presentedFrameState.install(attachment.fence)
            lastPresentedTerminalSequence = nil
            existing.updateFence(attachment.fence)
            compositor = existing
        } else {
            let frameReleaseLane = frameReleaseLane
            let frameReleaseFailures = frameReleaseFailureContinuation
            let diagnostics = TerminalBackendRenderDiagnostics.shared
            let diagnosticsWorkspaceContext = diagnosticsWorkspaceContext
            let accessibilityFrameDemand = accessibilityFrameDemand
            let presentedFrameState = presentedFrameState
            presentedFrameState.install(attachment.fence)
            compositor = try TerminalRenderCompositorView(
                fence: attachment.fence,
                frameReleaseHandler: { release in
                    if frameReleaseLane.enqueue(
                        release,
                        priority: .normal
                    ) == .stopped {
                        frameReleaseFailures.yield(.stopped)
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
        guard rendererStateIsCurrent(operationFence), self.receiver === receiver else {
            throw CancellationError()
        }
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
        let frameReleaseLane = frameReleaseLane
        let frameReleaseFailures = frameReleaseFailureContinuation
        let failureHandler: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.detached, self.visible else { return }
                self.rendererReconfigureNeeded = true
                self.scheduleDrain()
            }
        }
        receiveTask = Task.detached {
            [
                receiver,
                ingress,
                control,
                frameReleaseLane,
                frameReleaseFailures,
                failureHandler,
            ] in
            do {
                while !Task.isCancelled, !control.shouldStop {
                    switch try await receiver.receive(
                        timeoutMilliseconds: TerminalRenderFrameReceiver
                            .maximumReceiveTimeoutMilliseconds
                    ) {
                    case .frame(let frame):
                        if control.shouldStop {
                            if frameReleaseLane.enqueue(
                                TerminalRenderFrameRelease(frame: frame),
                                priority: .normal
                            ) == .stopped {
                                frameReleaseFailures.yield(.stopped)
                            }
                        } else {
                            _ = await ingress.enqueue(frame)
                        }
                    case .dropped(_, let release):
                        if let release {
                            if frameReleaseLane.enqueue(
                                release,
                                priority: .normal
                            ) == .stopped {
                                frameReleaseFailures.yield(.stopped)
                            }
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

    private func refreshFrontendEventRoute() {
        guard needsFrontendEventRoute else {
            deactivateFrontendEventRoute()
            return
        }
        guard frontendEventRoute == nil,
              frontendEventRegistrationTask == nil else { return }

        let generation = UUID()
        frontendEventRegistrationGeneration = generation
        let router = frontendEventRouter
        let presentationID = presentationID
        let workspaceID = currentWorkspaceID
        frontendEventRegistrationTask = Task { @MainActor [weak self, router] in
            let route = await router.register(
                presentationID: presentationID,
                workspaceID: workspaceID,
                rendererHandler: { [weak self] event in
                    guard let self,
                          self.acceptsFrontendEventRoute(
                            generation: generation,
                            presentationID: presentationID
                          ) else { return }
                    await self.handleRendererEvent(
                        event,
                        routeGeneration: generation,
                        routePresentationID: presentationID
                    )
                },
                rendererStreamEndedHandler: { [weak self] in
                    guard let self,
                          self.acceptsFrontendEventRoute(
                            generation: generation,
                            presentationID: presentationID
                          ) else { return }
                    await self.handleRendererEventStreamEnded(
                        routeGeneration: generation,
                        routePresentationID: presentationID
                    )
                },
                configHandler: { [weak self] update in
                    guard let self,
                          self.acceptsFrontendEventRoute(
                            generation: generation,
                            presentationID: presentationID
                          ),
                          update.revision != self.baseRenderConfigRevision else { return }
                    await self.installBaseRenderConfig(
                        update,
                        routeGeneration: generation,
                        routePresentationID: presentationID
                    )
                }
            )

            guard let self,
                  !Task.isCancelled,
                  self.acceptsFrontendEventRoute(
                    generation: generation,
                    presentationID: presentationID
                  ) else {
                await router.unregister(route)
                return
            }
            self.frontendEventRoute = route
            self.frontendEventRegistrationTask = nil
        }
    }

    private func acceptsFrontendEventRoute(
        generation: UUID,
        presentationID: UUID
    ) -> Bool {
        frontendEventRegistrationGeneration == generation
            && self.presentationID == presentationID
            && needsFrontendEventRoute
    }

    private func reindexFrontendEventRoute(workspaceID: UUID) async {
        if let route = frontendEventRoute {
            await frontendEventRouter.reindex(
                route,
                presentationID: presentationID,
                workspaceID: workspaceID
            )
            return
        }
        if frontendEventRegistrationTask != nil {
            deactivateFrontendEventRoute()
        }
        refreshFrontendEventRoute()
        await frontendEventRegistrationTask?.value
    }

    /// A hidden presentation remains routed only while its exact renderer
    /// quiescence proof or receiver retirement is still outstanding.
    private var needsFrontendEventRoute: Bool {
        !detached
            && attachedPresentation != nil
            && (visible
                || backendPresentationOpen
                || receiver != nil
                || receiverRetirementTask != nil)
    }

    private func deactivateFrontendEventRoute() {
        frontendEventRegistrationGeneration = UUID()
        frontendEventRegistrationTask?.cancel()
        frontendEventRegistrationTask = nil
        guard let route = frontendEventRoute else { return }
        frontendEventRoute = nil
        let router = frontendEventRouter
        Task { await router.unregister(route) }
    }

    private func handleRendererEventStreamEnded(
        routeGeneration: UUID? = nil,
        routePresentationID: UUID? = nil
    ) async {
        do {
            try await withRendererStateOperation {
                if let routeGeneration, let routePresentationID {
                    guard self.acceptsFrontendEventRoute(
                        generation: routeGeneration,
                        presentationID: routePresentationID
                    ) else { return }
                }
                try await self.handleRendererEventStreamEndedSerialized()
            }
        } catch {
            return
        }
    }

    private func handleFrameReleaseFailure(
        _: TerminalBackendFrameReleaseFailure
    ) async {
        guard !detached else { return }
        await handleRendererEventStreamEnded()
    }

    private func handleRendererEventStreamEndedSerialized() async throws {
        invalidateRendererStateOperations()
        let operationFence = rendererStateFence()
        let presentationID = presentationID
        let binding = binding
        cancelBindingTask()
        self.binding = nil
        bindingReconcileRequested = true
        state = .binding
        if await rotateReceiverAfterDaemonQuiescence(
            presentationID: presentationID,
            binding: binding
        ) {
            guard rendererStateGenerationIsCurrent(operationFence) else {
                throw CancellationError()
            }
            backendPresentationOpen = false
            refreshFrontendEventRoute()
            rendererReconfigureNeeded = true
            scheduleDrain()
        } else {
            guard rendererStateGenerationIsCurrent(operationFence) else {
                throw CancellationError()
            }
            markUnavailable()
        }
    }

    private func installBaseRenderConfig(
        _ update: TerminalBackendRenderConfigSnapshot,
        routeGeneration: UUID? = nil,
        routePresentationID: UUID? = nil
    ) async {
        do {
            try await withRendererStateOperation {
                if let routeGeneration, let routePresentationID {
                    guard self.acceptsFrontendEventRoute(
                        generation: routeGeneration,
                        presentationID: routePresentationID
                    ) else { return }
                }
                try await self.installBaseRenderConfigSerialized(update)
            }
        } catch {
            return
        }
    }

    private func installBaseRenderConfigSerialized(
        _ update: TerminalBackendRenderConfigSnapshot
    ) async throws {
        invalidateRendererStateOperations()
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
            let operationFence = rendererStateFence()
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
            guard rendererStateIsCurrent(operationFence) else {
                throw CancellationError()
            }
        }
        backendPresentationOpen = false
        let retirementFence = rendererStateFence()
        await rotateReceiverAfterQuiescenceProof(expectedFence: retirementFence)
        guard rendererStateGenerationIsCurrent(retirementFence) else {
            throw CancellationError()
        }
        refreshFrontendEventRoute()
        rendererReconfigureNeeded = true
        scheduleDrain()
    }

    private func installRendererActivation(
        _ activation: TerminalBackendRendererActivation
    ) async throws {
        guard !detached,
              visible,
              activation.presentationID == presentationID,
              let receiver else { return }
        let operationFence = rendererStateFence()
        do {
            try await receiver.authorize(worker: activation.worker)
        } catch {
            guard rendererStateIsCurrent(operationFence), self.receiver === receiver else {
                throw CancellationError()
            }
            throw error
        }
        guard rendererStateIsCurrent(operationFence), self.receiver === receiver else {
            throw CancellationError()
        }
        await receiver.updateFence(activation.fence)
        guard rendererStateIsCurrent(operationFence), self.receiver === receiver else {
            throw CancellationError()
        }
        do {
            try await client.activateRenderer(activation)
        } catch {
            guard rendererStateIsCurrent(operationFence), self.receiver === receiver else {
                throw CancellationError()
            }
            throw error
        }
        guard rendererStateIsCurrent(operationFence), self.receiver === receiver else {
            throw CancellationError()
        }
    }

    private func handleRendererEvent(
        _ event: TerminalBackendRendererEvent,
        routeGeneration: UUID? = nil,
        routePresentationID: UUID? = nil
    ) async {
        do {
            try await withRendererStateOperation {
                if let routeGeneration, let routePresentationID {
                    guard self.acceptsFrontendEventRoute(
                        generation: routeGeneration,
                        presentationID: routePresentationID
                    ) else { return }
                }
                try await self.handleRendererEventSerialized(event)
            }
        } catch {
            return
        }
    }

    private func handleRendererEventSerialized(
        _ event: TerminalBackendRendererEvent
    ) async throws {
        switch event {
        case .workerChanged(let eventPresentationID, let changed):
            guard eventPresentationID == presentationID,
                  changed.workspaceID.rawValue == currentWorkspaceID else { return }
            let presentedEpoch = compositor?.fence.rendererEpoch
            let oldWorkerDied = presentedEpoch == changed.priorRendererEpoch
                && (changed.rendererEpoch != presentedEpoch || changed.state != .ready)
            if oldWorkerDied {
                invalidateRendererStateOperations()
                let operationFence = rendererStateFence()
                await rotateReceiverAfterQuiescenceProof(expectedFence: operationFence)
                guard rendererStateGenerationIsCurrent(operationFence) else {
                    throw CancellationError()
                }
                backendPresentationOpen = false
                refreshFrontendEventRoute()
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
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                invalidateRendererStateOperations()
                let operationFence = rendererStateFence()
                if await rotateReceiverAfterDaemonQuiescence(
                    presentationID: presentationID,
                    binding: binding
                ) {
                    guard rendererStateGenerationIsCurrent(operationFence) else {
                        throw CancellationError()
                    }
                    backendPresentationOpen = false
                    refreshFrontendEventRoute()
                    rendererReconfigureNeeded = true
                    scheduleDrain()
                } else {
                    guard rendererStateGenerationIsCurrent(operationFence) else {
                        throw CancellationError()
                    }
                    markUnavailable()
                }
            }
        case .presentationInvalidated:
            // The frontend router converts this control event into its route's
            // renderer-stream-ended handler before it reaches a runtime mailbox.
            return
        case .connectionLost(let authority):
            guard let lostBinding = binding, lostBinding.authority == authority else { return }
            invalidateRendererStateOperations()
            let operationFence = rendererStateFence()
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
                guard rendererStateGenerationIsCurrent(operationFence) else {
                    throw CancellationError()
                }
                backendPresentationOpen = false
                refreshFrontendEventRoute()
                scheduleDrain()
            } else {
                guard rendererStateGenerationIsCurrent(operationFence) else {
                    throw CancellationError()
                }
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

    func debugHasFrontendEventRouteForTesting() -> Bool {
        frontendEventRoute != nil
    }

    func debugHasFrontendEventRegistrationTaskForTesting() -> Bool {
        frontendEventRegistrationTask != nil
    }

    func debugBackendPresentationOpenForTesting() -> Bool {
        backendPresentationOpen
    }

    func debugFrontendLifecycleWaiterCountForTesting() async -> Int {
        (await frontendEventRouter.snapshot()).lifecycleWaiterCount
    }

    func debugFrontendEventRouterSnapshotForTesting() async
        -> TerminalBackendFrontendEventRouterSnapshot
    {
        await frontendEventRouter.snapshot()
    }

    func debugWaitForFrontendEventRouteCountForTesting(_ count: Int) async {
        await frontendEventRouter.waitForRouteCount(count)
    }

    func debugWaitForFrontendRendererDeliveryCountForTesting(_ count: Int) async {
        await frontendEventRouter.waitForRendererDeliveryCount(count)
    }

    func debugWaitForFrontendConfigDeliveryCountForTesting(_ count: Int) async {
        await frontendEventRouter.waitForConfigDeliveryCount(count)
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
    private func rotateReceiverAfterQuiescenceProof(
        expectedFence: RendererStateFence? = nil
    ) async {
        if let receiverRetirementTask {
            guard await receiverRetirementTask.value else { return }
        }
        if let expectedFence,
           !rendererStateGenerationIsCurrent(expectedFence) {
            return
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
                binding: binding,
                eventRouter: self.frontendEventRouter
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
        let releaseMetricsBeforeRetirement = frameReleaseLane.metrics()
        let compositorIngress = compositor?.frameIngress
        let retirement = receiver.map {
            TerminalBackendReceiverRetirement(
                receiver: $0,
                receiveTask: receiveTask,
                receiveLoopControl: receiveLoopControl,
                compositorIngress: compositorIngress,
                releaseMetricsBeforeRetirement: releaseMetricsBeforeRetirement
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
        await retirement.compositorIngress?.stopAndWait()
        await frameReleaseLane.waitUntilIdle()
        let releaseMetrics = frameReleaseLane.metrics()
        guard releaseMetrics.capacityFailures
                == retirement.releaseMetricsBeforeRetirement.capacityFailures,
              releaseMetrics.sendFailures
                == retirement.releaseMetricsBeforeRetirement.sendFailures
        else {
            retainUnresolvedReceiverRetirement(retirement)
            return false
        }
        do {
            let releases = try await retirement.receiver.drainQuiescedFrames()
            for release in releases {
                guard frameReleaseLane.enqueue(
                    release,
                    priority: .recovery
                ) == .accepted else {
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
        await frameReleaseLane.waitUntilIdle()
        let finalReleaseMetrics = frameReleaseLane.metrics()
        guard finalReleaseMetrics.capacityFailures
                == releaseMetrics.capacityFailures,
              finalReleaseMetrics.sendFailures == releaseMetrics.sendFailures
        else {
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
        let operationFence = rendererStateFence()
        await rotateReceiverAfterQuiescenceProof(expectedFence: operationFence)
        guard rendererStateGenerationIsCurrent(operationFence) else { return }
        refreshFrontendEventRoute()
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
        invalidateRendererStateOperations()
        detached = true
        bindingReconcileRequested = false
        drainTask?.cancel()
        drainTask = nil
        cancelBindingTask()
        let pendingAdoption = placementAdoptionTask
        placementAdoptionTask = nil
        deactivateFrontendEventRoute()
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
                binding: binding,
                eventRouter: self.frontendEventRouter
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
