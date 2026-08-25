internal import CMUXMobileCore
import Foundation

actor MobileCoreRPCSession {
    typealias TransportFactory = @Sendable () throws -> any CmxByteTransport
    typealias IndependentEventByteStreamFactory = @Sendable () async throws -> CmxIndependentEventByteStream
    typealias ConnectedCandidateHook = @Sendable (_ candidate: any CmxByteTransport) async -> Void
    typealias TransportConnectObserver = @Sendable (MobileRPCTransportConnectEvent) -> Void
    typealias TearDownRegistrationHook = @Sendable () async -> Void
    enum PendingRequestSettlement {
        case response(Result<Data, MobileShellConnectionError>)
        case cancelled
    }
    enum PipelinedRequestSettlement {
        case pending
        case awaiting(PendingContinuation)
        case settled(PendingRequestSettlement)
    }
    typealias PendingContinuation = CheckedContinuation<PendingRequestSettlement, Never>
    typealias ConnectingTask = (
        id: UUID,
        lease: MobileRPCConnectAttemptLease?,
        task: Task<any CmxByteTransport, any Error>,
        cancellationClose: MobileRPCConnectCancellationClose,
        diagnosticAttemptID: Int?,
        diagnosticStartedAt: ContinuousClock.Instant?,
        waiters: Set<UUID>,
        completed: Bool
    )
    static let defaultAbandonedConnectCleanupTimeoutNanoseconds: UInt64 = 1_000_000_000
    static let defaultLateAbandonedConnectCloseTimeoutNanoseconds: UInt64 = 5_000_000_000
    static let defaultCancelledWriteCompletionGraceNanoseconds: UInt64 = 250_000_000
    static let maximumReceiveBufferByteCount =
        MobileSyncFrameCodec.defaultMaximumFrameByteCount
        + MobileSyncFrameCodec.headerByteCount
    static let maximumDecodedFrameCountPerRead = 256

    struct EventSubscription {
        let id: UUID
        let stream: AsyncStream<MobileEventEnvelope>
    }

    struct EventListener {
        let topics: Set<String>
        let continuation: AsyncStream<MobileEventEnvelope>.Continuation
    }

    private struct PendingWrite: Sendable {
        let id: UUID
        let requestID: String
        let frame: Data
    }

    private struct ActiveWrite: Sendable {
        let connectionID: UUID
        let requestID: String
        let task: Task<Void, any Error>
        var cancelledRequestResolutionTask: Task<Void, Never>?
    }

    struct IndependentEventPreparation: Sendable {
        let id: UUID
        let task: Task<CmxIndependentEventByteStream, any Error>
    }

    struct IndependentEventReader: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    let taskTimeout = RPCTaskTimeout()
    private let connectAttemptKey: MobileRPCConnectAttemptKey?
    let connectAttemptRegistry: MobileRPCConnectAttemptRegistry
    let abandonedConnectCleanupTimeoutNanoseconds: UInt64
    let lateAbandonedConnectCloseTimeoutNanoseconds: UInt64
    let cancelledWriteCompletionGraceNanoseconds: UInt64
    private let makeTransport: TransportFactory
    let makeIndependentEventByteStream: IndependentEventByteStreamFactory?
    private let didReceiveConnectedCandidate: ConnectedCandidateHook?
    private let diagnosticTransport: DiagnosticTransportKind?
    private let transportConnectObserver: TransportConnectObserver?
    private let tearDownRegistrationHook: TearDownRegistrationHook?
    /// Current shell ownership role. Connected transports that support role
    /// rebinding receive updates without replacing their admitted session.
    private var transportSessionPurpose: CmxTransportSessionPurpose?
    // The getter is internal so the debug-only release-gate extension can
    // inspect the installed transport. Only this actor's production code can
    // replace it.
    private(set) var transport: (any CmxByteTransport)?
    /// The global physical-resource lease stays live for the installed
    /// transport's full lifetime. Teardown transfers it to the exact close
    /// task, so a hanging installed close consumes the same bounded cleanup
    /// budget as an abandoned connect.
    private var installedConnectLease: MobileRPCConnectAttemptLease?
    private var connectionTask: ConnectingTask?
    private var recordedConnectCancellationAttemptIDs: Set<Int> = []
    private var installedConnectionID: UUID?
    private var readerTask: Task<Void, Never>?
    var independentEventPreparation: IndependentEventPreparation?
    var independentEventReader: IndependentEventReader?
    /// Subscription stream IDs that already made their one optional-lane
    /// negotiation attempt during this control-session generation.
    var independentEventSubscriptionStreamIDs: Set<String> = []
    var pending: [String: PendingContinuation] = [:]
    var pipelinedPending: [String: PipelinedRequestSettlement] = [:]
    var requestTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var queuedWriteIDs: [String: UUID] = [:]
    private var cancelledQueuedWriteIDs: Set<UUID> = []
    // `internal` so cancellation tests can observe the writer-queue gate via
    // `@testable import` without adding a production debug hook.
    var queuedRequestIDs: Set<String> { Set(queuedWriteIDs.keys) }
    private var writeResolutionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    // `internal` so recovery tests can assert waiter cleanup via `@testable import`.
    var writeResolutionWaiterCount: Int { writeResolutionWaiters.count }
    var listeners: [UUID: EventListener] = [:]
    var isTearingDown: Bool = false
    private var tearDownWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeQueue: AsyncStream<PendingWrite>.Continuation?
    private var writerTask: Task<Void, Never>?
    private var activeWrite: ActiveWrite?
    /// Each installed close has independent lifetime and is also retained by
    /// the shared registry, so session deallocation cannot strand a queued
    /// transport or its route lease.
    private var transportCloseTasks: [UUID: Task<Void, Never>] = [:]
    var abandonedConnectionCleanupTasks: [UUID: Task<Void, Never>] = [:]

    init(
        connectAttemptKey: MobileRPCConnectAttemptKey? = nil,
        connectAttemptRegistry: MobileRPCConnectAttemptRegistry = MobileRPCConnectAttemptRegistry(),
        abandonedConnectCleanupTimeoutNanoseconds: UInt64 = 1_000_000_000,
        lateAbandonedConnectCloseTimeoutNanoseconds: UInt64 = 5_000_000_000,
        cancelledWriteCompletionGraceNanoseconds: UInt64 =
            MobileCoreRPCSession.defaultCancelledWriteCompletionGraceNanoseconds,
        makeTransport: @escaping TransportFactory,
        makeIndependentEventByteStream: IndependentEventByteStreamFactory? = nil,
        didReceiveConnectedCandidate: ConnectedCandidateHook? = nil,
        diagnosticTransport: DiagnosticTransportKind? = nil,
        transportConnectObserver: TransportConnectObserver? = nil,
        initialTransportSessionPurpose: CmxTransportSessionPurpose? = nil,
        tearDownRegistrationHook: TearDownRegistrationHook? = nil
    ) {
        self.connectAttemptKey = connectAttemptKey
        self.connectAttemptRegistry = connectAttemptRegistry
        self.abandonedConnectCleanupTimeoutNanoseconds = abandonedConnectCleanupTimeoutNanoseconds
        self.lateAbandonedConnectCloseTimeoutNanoseconds = lateAbandonedConnectCloseTimeoutNanoseconds
        self.cancelledWriteCompletionGraceNanoseconds =
            cancelledWriteCompletionGraceNanoseconds
        self.makeTransport = makeTransport
        self.makeIndependentEventByteStream = makeIndependentEventByteStream
        self.didReceiveConnectedCandidate = didReceiveConnectedCandidate
        self.diagnosticTransport = diagnosticTransport
        self.transportConnectObserver = transportConnectObserver
        self.transportSessionPurpose = initialTransportSessionPurpose
        self.tearDownRegistrationHook = tearDownRegistrationHook
    }

    deinit {
        let connecting = connectionTask
        if let connecting,
           let attemptID = connecting.diagnosticAttemptID,
           let diagnosticTransport,
           let transportConnectObserver {
            transportConnectObserver(.cancelled(
                attemptID: attemptID,
                transport: diagnosticTransport,
                reason: .sessionDeinitialized,
                elapsedMilliseconds: Self.elapsedMilliseconds(
                    since: connecting.diagnosticStartedAt ?? ContinuousClock.now
                )
            ))
        }
        connecting?.task.cancel()
        let installedTransport = transport
        let installedLease = installedConnectLease
        let registry = connectAttemptRegistry
        if let connecting {
            Task.detached {
                await registry.handOffPhysicalCleanup(
                    lease: connecting.lease
                ) {
                    do {
                        let candidate = try await connecting.task.value
                        if let cancellationCloseTask =
                            await connecting.cancellationClose.task() {
                            await cancellationCloseTask.value
                        }
                        await candidate.close()
                    } catch {
                        if let cancellationCloseTask =
                            await connecting.cancellationClose.task() {
                            await cancellationCloseTask.value
                        }
                    }
                }
            }
        }
        if installedTransport != nil || installedLease != nil {
            Task.detached {
                await registry.handOffPhysicalCleanup(
                    lease: installedLease
                ) {
                    await installedTransport?.close()
                }
            }
        }
        readerTask?.cancel()
        independentEventPreparation?.task.cancel()
        independentEventReader?.task.cancel()
        activeWrite?.task.cancel()
        activeWrite?.cancelledRequestResolutionTask?.cancel()
        writerTask?.cancel()
        writeQueue?.finish()
    }

    func send(payload: Data, requestID: String, deadlineUptimeNanoseconds: UInt64) async throws -> Data {
        try await waitForCancelledActiveWriteResolution(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        _ = try await ensureConnected(
            timeoutNanoseconds: try taskTimeout.remainingNanoseconds(until: deadlineUptimeNanoseconds)
        )
        let frame = try MobileSyncFrameCodec.encodeFrame(payload)
        let responseTimeoutNanoseconds = try taskTimeout.remainingNanoseconds(until: deadlineUptimeNanoseconds)

        let settlement: PendingRequestSettlement = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard pending[requestID] == nil,
                      pipelinedPending[requestID] == nil,
                      queuedWriteIDs[requestID] == nil else {
                    continuation.resume(returning: .response(.failure(.invalidResponse)))
                    return
                }
                let queuedWriteID = UUID()
                pending[requestID] = continuation
                armResponseTimeout(
                    requestID: requestID,
                    timeoutNanoseconds: responseTimeoutNanoseconds
                )
                guard let queue = writeQueue else {
                    requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
                    pending.removeValue(forKey: requestID)
                    continuation.resume(returning: .response(.failure(.connectionClosed)))
                    return
                }
                queuedWriteIDs[requestID] = queuedWriteID
                _ = queue.yield(PendingWrite(id: queuedWriteID, requestID: requestID, frame: frame))
            }
        } onCancel: {
            Task {
                await self.cancelPendingRequest(requestID: requestID)
            }
        }
        return try Self.resolvePendingSettlement(settlement, isCancelled: Task.isCancelled)
    }

    func beginSend(
        payload: Data,
        requestID: String,
        deadlineUptimeNanoseconds: UInt64
    ) async throws {
        // Same demand gate as send(): new work must not queue behind a
        // cancelled unresolved write, or it hangs until its own deadline
        // behind a transport its timeout may have to condemn.
        try await waitForCancelledActiveWriteResolution(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        _ = try await ensureConnected(
            timeoutNanoseconds: try taskTimeout.remainingNanoseconds(
                until: deadlineUptimeNanoseconds
            )
        )
        let frame = try MobileSyncFrameCodec.encodeFrame(payload)
        let responseTimeoutNanoseconds = try taskTimeout.remainingNanoseconds(
            until: deadlineUptimeNanoseconds
        )
        guard pending[requestID] == nil,
              pipelinedPending[requestID] == nil,
              queuedWriteIDs[requestID] == nil else {
            throw MobileShellConnectionError.invalidResponse
        }
        guard let queue = writeQueue else {
            throw MobileShellConnectionError.connectionClosed
        }
        let queuedWriteID = UUID()
        pipelinedPending[requestID] = .pending
        armResponseTimeout(
            requestID: requestID,
            timeoutNanoseconds: responseTimeoutNanoseconds
        )
        queuedWriteIDs[requestID] = queuedWriteID
        _ = queue.yield(PendingWrite(
            id: queuedWriteID,
            requestID: requestID,
            frame: frame
        ))
    }

    func awaitResponse(requestID: String) async throws -> Data {
        let settlement: PendingRequestSettlement = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                switch pipelinedPending[requestID] {
                case .pending:
                    pipelinedPending[requestID] = .awaiting(continuation)
                case let .settled(settlement):
                    pipelinedPending.removeValue(forKey: requestID)
                    continuation.resume(returning: settlement)
                case .awaiting, nil:
                    continuation.resume(
                        returning: .response(.failure(.invalidResponse))
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelPendingRequest(requestID: requestID)
            }
        }
        return try Self.resolvePendingSettlement(
            settlement,
            isCancelled: Task.isCancelled
        )
    }

    func addEventListener(topics: Set<String>) -> EventSubscription {
        let id = UUID()
        var continuation: AsyncStream<MobileEventEnvelope>.Continuation!
        let stream = AsyncStream<MobileEventEnvelope>(bufferingPolicy: .bufferingNewest(256)) { cont in
            continuation = cont
        }
        listeners[id] = EventListener(topics: topics, continuation: continuation)
        continuation.onTermination = { @Sendable [weak self] _ in
            guard let self else { return }
            Task { await self.removeListener(id: id) }
        }
        return EventSubscription(id: id, stream: stream)
    }

    func removeListener(id: UUID) {
        listeners.removeValue(forKey: id)
    }

    func updateTransportSessionPurpose(
        _ purpose: CmxTransportSessionPurpose
    ) async {
        transportSessionPurpose = purpose
        guard let updating =
            transport as? any CmxByteTransportSessionPurposeUpdating else {
            return
        }
        let connectionID = installedConnectionID
        var appliedPurpose: CmxTransportSessionPurpose?
        while installedConnectionID == connectionID,
              transport != nil,
              let currentPurpose = transportSessionPurpose,
              currentPurpose != appliedPurpose {
            await updating.updateSessionPurpose(currentPurpose)
            appliedPurpose = currentPurpose
        }
    }

    /// Returns the concrete path currently carrying the installed transport,
    /// or `.unavailable` before admission/after teardown.
    func currentTransportPath() async -> CmxTransportPath {
        guard let transport,
              let observing = transport as? any CmxByteTransportPathObserving else {
            return .unavailable
        }
        return await observing.currentTransportPath()
    }

    /// Returns the process-local admitted session correlation ID, when the
    /// installed transport exposes one for diagnostics.
    func transportDiagnosticSessionID() async -> Int? {
        guard let transport,
              let identifying = transport as? any CmxByteTransportDiagnosticSessionIdentifying else {
            return nil
        }
        return await identifying.transportDiagnosticSessionID()
    }

    /// Subscribes to concrete path changes for the installed transport. The
    /// stream finishes with the transport lifecycle; callers must recreate it
    /// after replacing this session's client.
    func transportPathChanges() async -> AsyncStream<CmxTransportPath> {
        guard let transport,
              let observing = transport as? any CmxByteTransportPathObserving else {
            return AsyncStream { continuation in
                continuation.yield(.unavailable)
                continuation.finish()
            }
        }
        return await observing.transportPathChanges()
    }

    func tearDown(error: MobileShellConnectionError) async {
        if isTearingDown {
            await withCheckedContinuation {
                tearDownWaiters.append($0)
            }
            return
        }
        isTearingDown = true
        defer {
            isTearingDown = false
            let waiters = tearDownWaiters
            tearDownWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        let pendingSnapshot = pending
        pending.removeAll()
        let pipelinedSnapshot = pipelinedPending
        pipelinedPending.removeAll()
        let timeoutSnapshot = requestTimeoutTasks
        requestTimeoutTasks.removeAll()
        queuedWriteIDs.removeAll()
        cancelledQueuedWriteIDs.removeAll()
        for (_, task) in timeoutSnapshot {
            task.cancel()
        }
        for (_, cont) in pendingSnapshot {
            cont.resume(returning: .response(.failure(error)))
        }
        for (requestID, settlement) in pipelinedSnapshot {
            switch settlement {
            case let .awaiting(continuation):
                continuation.resume(returning: .response(.failure(error)))
            case .pending:
                // Preserve the real teardown failure for a handle nobody has
                // awaited yet; dropping it would misreport the outcome as a
                // protocol error (invalidResponse) when response() is called.
                pipelinedPending[requestID] = .settled(.response(.failure(error)))
            case .settled:
                // Keep an already-settled outcome claimable; entries are
                // bounded by the caller's pipeline window and are removed on
                // claim or abandon.
                pipelinedPending[requestID] = settlement
            }
        }
        let listenerSnapshot = listeners
        listeners.removeAll()
        for (_, listener) in listenerSnapshot {
            listener.continuation.finish()
        }
        writeQueue?.finish()
        writeQueue = nil
        activeWrite?.task.cancel()
        activeWrite?.cancelledRequestResolutionTask?.cancel()
        activeWrite = nil
        resumeWriteResolutionWaiters()
        writerTask?.cancel()
        writerTask = nil
        let connecting = connectionTask
        if let connecting {
            recordConnectCancellation(connecting, reason: .sessionTeardown)
        }
        connecting?.task.cancel()
        connectionTask = nil
        installedConnectionID = nil
        let installedLease = installedConnectLease
        installedConnectLease = nil
        let transportToClose = transport
        transport = nil
        readerTask?.cancel()
        readerTask = nil
        independentEventPreparation?.task.cancel()
        independentEventPreparation = nil
        independentEventReader?.task.cancel()
        independentEventReader = nil
        independentEventSubscriptionStreamIDs.removeAll()
        await tearDownRegistrationHook?()
        if let transportToClose {
            await enqueueTransportClose(
                transportToClose,
                lease: installedLease
            )
        } else {
            await connectAttemptRegistry.finishConnect(
                lease: installedLease
            )
        }
        if let connecting { await abandonConnectionTask(connecting) }
    }

    /// Wait until every installed transport detached by teardown has completed
    /// `close()` and every abandoned dial has either closed or transferred its
    /// late cleanup to the shared route registry. Ordinary reconnects do not
    /// block on this bounded drain, but a same-peer ownership handoff observes
    /// it before redialing.
    func waitForTransportDrain() async {
        while !transportCloseTasks.isEmpty
            || !abandonedConnectionCleanupTasks.isEmpty {
            let installedTransportCloses =
                Array(transportCloseTasks.values)
            let abandonedConnectCleanups =
                Array(abandonedConnectionCleanupTasks.values)
            for close in installedTransportCloses {
                await close.value
            }
            for cleanup in abandonedConnectCleanups {
                await cleanup.value
            }
        }
    }

    // MARK: - private

    private func ensureConnected(timeoutNanoseconds: UInt64) async throws -> any CmxByteTransport {
        // `tearDown` is actor-reentrant while it awaits transport close and
        // abandoned-connect cleanup. Reject requests that arrive in that
        // window so a stale client cannot install a replacement transport
        // underneath the shell owner that is retiring it.
        guard !isTearingDown else {
            throw MobileShellConnectionError.connectionClosed
        }
        if let transport { return transport }
        // A cancellation-ignoring connect or close still owns this client's
        // production route until cleanup closes it or transfers its late
        // watcher to the shared route registry. Do not let repeated requests
        // append more retained cleanup graphs before that bounded handoff.
        // Direct untracked sessions have no shared route authority and retain
        // their cooperative-cancellation retry semantics.
        if connectAttemptKey != nil,
           !abandonedConnectionCleanupTasks.isEmpty {
            throw MobileShellConnectionError.routeCleanupBlocked
        }
        let waiterID = UUID()
        let connectionID: UUID
        let connectLease: MobileRPCConnectAttemptLease?
        let task: Task<any CmxByteTransport, any Error>
        let cancellationClose: MobileRPCConnectCancellationClose
        if let existing = connectionTask {
            connectionID = existing.id
            connectLease = existing.lease
            task = existing.task
            cancellationClose = existing.cancellationClose
            connectionTask?.waiters.insert(waiterID)
        } else {
            switch await connectAttemptRegistry.beginConnect(
                key: connectAttemptKey
            ) {
            case .granted(let lease):
                connectLease = lease
            case .busy:
                // A gate refusal is instantaneous and never touched the
                // network; reporting it as a timeout fabricated sub-30ms
                // "timedOut" failures that poisoned lastFailureEvent.
                throw MobileShellConnectionError.connectAttemptGated
            case .cleanupBlocked:
                throw MobileShellConnectionError.routeCleanupBlocked
            }
            let connectAttemptID = Int.random(in: 1...Int.max)
            let connectStartedAt = ContinuousClock.now
            let diagnosticTransport = diagnosticTransport
            let transportConnectObserver = transportConnectObserver
            let initialSessionPurpose = transportSessionPurpose
            let reportCancelledConnect: @Sendable () -> Void = {
                if let diagnosticTransport, let transportConnectObserver {
                    transportConnectObserver(
                        .failed(
                            attemptID: connectAttemptID,
                            transport: diagnosticTransport,
                            failure: .cancelled,
                            elapsedMilliseconds: Self.elapsedMilliseconds(
                                since: connectStartedAt
                            )
                        )
                    )
                }
            }
            if let diagnosticTransport, let transportConnectObserver {
                transportConnectObserver(
                    .attempt(
                        attemptID: connectAttemptID,
                        transport: diagnosticTransport
                    )
                )
            }
            let candidate: any CmxByteTransport
            do {
                candidate = try makeTransport()
            } catch let rejected as MobileRPCRejectedTransportDisposal {
                await connectAttemptRegistry.handOffPhysicalCleanup(
                    lease: connectLease
                ) {
                    await rejected.task.value
                }
                if Task.isCancelled {
                    reportCancelledConnect()
                    throw CancellationError()
                }
                let error = MobileShellConnectionError.connectionClosed
                if let diagnosticTransport,
                   let transportConnectObserver {
                    transportConnectObserver(
                        .failed(
                            attemptID: connectAttemptID,
                            transport: diagnosticTransport,
                            failure: DiagnosticFailureKind.classify(error),
                            elapsedMilliseconds: Self.elapsedMilliseconds(
                                since: connectStartedAt
                            )
                        )
                    )
                }
                throw error
            } catch {
                await connectAttemptRegistry.finishConnect(lease: connectLease)
                if error is CancellationError || Task.isCancelled {
                    reportCancelledConnect()
                    throw CancellationError()
                }
                if let diagnosticTransport, let transportConnectObserver {
                    transportConnectObserver(
                        .failed(
                            attemptID: connectAttemptID,
                            transport: diagnosticTransport,
                            failure: DiagnosticFailureKind.classify(error),
                            elapsedMilliseconds: Self.elapsedMilliseconds(
                                since: connectStartedAt
                            )
                        )
                    )
                }
                throw error
            }
            connectionID = UUID()
            cancellationClose =
                MobileRPCConnectCancellationClose()
            task = Task.detached {
                do {
                    if let initialSessionPurpose,
                       let updating =
                        candidate as? any CmxByteTransportSessionPurposeUpdating {
                        await updating.updateSessionPurpose(
                            initialSessionPurpose
                        )
                    }
                    try await withTaskCancellationHandler {
                        try await candidate.connect()
                    } onCancel: {
                        Task.detached {
                            await cancellationClose.start(candidate)
                        }
                    }
                    if Task.isCancelled {
                        _ = await cancellationClose.task()
                    } else {
                        await cancellationClose.finishWithoutClose()
                    }
                    // A cancellation-ignoring transport must still return its
                    // late candidate to the existing abandoned-connect cleanup
                    // path so that path can close it again after completion.
                    // Report the abandoned attempt as cancelled without
                    // replacing that result with `CancellationError`.
                    if Task.isCancelled {
                        reportCancelledConnect()
                    } else if let diagnosticTransport,
                              let transportConnectObserver {
                        transportConnectObserver(
                            .connected(
                                attemptID: connectAttemptID,
                                transport: diagnosticTransport,
                                elapsedMilliseconds:
                                    Self.elapsedMilliseconds(since: connectStartedAt),
                                sessionID: await (
                                    candidate as? any CmxByteTransportDiagnosticSessionIdentifying
                                )?.transportDiagnosticSessionID()
                            )
                        )
                        if let observing = candidate as? any CmxByteTransportPathObserving {
                            transportConnectObserver(.pathObserved(
                                attemptID: connectAttemptID,
                                path: (await observing.currentTransportPath())
                                    .diagnosticPathKind
                            ))
                        }
                    }
                    return candidate
                } catch is CancellationError {
                    if Task.isCancelled {
                        _ = await cancellationClose.task()
                    } else {
                        await cancellationClose.finishWithoutClose()
                    }
                    reportCancelledConnect()
                    throw CancellationError()
                } catch {
                    // Some transports surface their close error instead of
                    // `CancellationError` after the cancellation handler closes
                    // them. Treat the task's cancellation bit as authoritative
                    // so an abandoned dial reports cancelled, never a false
                    // transport failure.
                    if Task.isCancelled {
                        _ = await cancellationClose.task()
                        reportCancelledConnect()
                        throw CancellationError()
                    }
                    await cancellationClose.finishWithoutClose()
                    if let diagnosticTransport, let transportConnectObserver {
                        transportConnectObserver(
                            .failed(
                                attemptID: connectAttemptID,
                                transport: diagnosticTransport,
                                failure: DiagnosticFailureKind.classify(error),
                                elapsedMilliseconds: Self.elapsedMilliseconds(
                                    since: connectStartedAt
                                )
                            )
                        )
                    }
                    throw error
                }
            }
            connectionTask = (
                id: connectionID,
                lease: connectLease,
                task: task,
                cancellationClose: cancellationClose,
                diagnosticAttemptID: connectAttemptID,
                diagnosticStartedAt: connectStartedAt,
                waiters: [waiterID],
                completed: false
            )
            Task.detached { [weak self] in
                _ = await task.result
                await self?.markConnectingCompleted(id: connectionID)
            }
        }

        let candidate: any CmxByteTransport
        let callerCancelled: Bool
        do {
            let connected = try await taskTimeout.value(task, timeoutNanoseconds: timeoutNanoseconds)
            if let didReceiveConnectedCandidate {
                await didReceiveConnectedCandidate(connected)
            }
            await Task.yield()
            callerCancelled = Task.isCancelled
            candidate = connected
        } catch {
            if Task.isCancelled {
                await cancelConnectingWaiter(id: connectionID, waiterID: waiterID)
                throw CancellationError()
            }
            if case MobileShellConnectionError.requestTimedOut = error {
                await timeoutConnectingWaiter(id: connectionID, waiterID: waiterID)
            } else if error is CancellationError {
                if connectionTask?.id == connectionID {
                    connectionTask = nil
                    await connectAttemptRegistry.finishConnect(lease: connectLease)
                }
            } else if connectionTask?.id == connectionID {
                connectionTask = nil
                await connectAttemptRegistry.finishConnect(lease: connectLease)
            }
            throw error
        }

        if let transport {
            if installedConnectionID != connectionID {
                closeUninstalledConnectedCandidate(candidate, lease: connectLease)
            }
            if callerCancelled {
                throw CancellationError()
            }
            return transport
        }

        guard connectionTask?.id == connectionID else {
            closeUninstalledConnectedCandidate(candidate, lease: connectLease)
            throw MobileShellConnectionError.connectionClosed
        }

        if let updating =
            candidate as? any CmxByteTransportSessionPurposeUpdating {
            var appliedPurpose: CmxTransportSessionPurpose?
            while let currentSessionPurpose = transportSessionPurpose,
                  currentSessionPurpose != appliedPurpose {
                await updating.updateSessionPurpose(currentSessionPurpose)
                appliedPurpose = currentSessionPurpose
                // Another waiter for this same connection may have installed
                // the shared candidate while this actor was suspended in the
                // transport update. Reuse that installed generation instead of
                // treating the candidate as stale and closing the live session.
                if let installedTransport = transport {
                    guard installedConnectionID == connectionID else {
                        closeUninstalledConnectedCandidate(
                            candidate,
                            lease: connectLease
                        )
                        throw MobileShellConnectionError.connectionClosed
                    }
                    if callerCancelled || Task.isCancelled {
                        throw CancellationError()
                    }
                    return installedTransport
                }
                guard connectionTask?.id == connectionID,
                      !isTearingDown else {
                    closeUninstalledConnectedCandidate(
                        candidate,
                        lease: connectLease
                    )
                    throw MobileShellConnectionError.connectionClosed
                }
            }
        }

        if callerCancelled {
            connectionTask?.waiters.remove(waiterID)
        }

        if callerCancelled, connectionTask?.waiters.isEmpty == true {
            connectionTask = nil
            closeUninstalledConnectedCandidate(candidate, lease: connectLease)
            throw CancellationError()
        }

        let (stream, continuation) = AsyncStream<PendingWrite>.makeStream(
            bufferingPolicy: .unbounded
        )
        let nextReaderTask = Task { [weak self] in
            guard let self else { return }
            await self.readLoop(
                transport: candidate,
                connectionID: connectionID
            )
        }
        let nextWriterTask = Task { [weak self] in
            guard let self else { return }
            await self.writeLoop(
                transport: candidate,
                connectionID: connectionID,
                frames: stream
            )
        }

        // Publish one coherent installed generation without suspending. Readers
        // use `transport` as the fast-path readiness flag, so it must become
        // visible only after its reader and writer infrastructure is installed.
        connectionTask = nil
        installedConnectionID = connectionID
        readerTask = nextReaderTask
        writeQueue = continuation
        writerTask = nextWriterTask
        transport = candidate
        installedConnectLease = connectLease

        guard installedConnectionID == connectionID,
              transport != nil,
              !isTearingDown else {
            throw MobileShellConnectionError.connectionClosed
        }
        if callerCancelled || Task.isCancelled {
            throw CancellationError()
        }
        return candidate
    }

    private nonisolated static func elapsedMilliseconds(
        since start: ContinuousClock.Instant
    ) -> Int {
        let components = start.duration(to: .now).components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        return max(0, Int(milliseconds))
    }

    private func cancelConnectingWaiter(id connectionID: UUID, waiterID: UUID) async {
        guard transport == nil,
              let connecting = connectionTask,
              connecting.id == connectionID else {
            return
        }
        connectionTask?.waiters.remove(waiterID)
        guard connectionTask?.waiters.isEmpty == true else { return }
        if connecting.completed {
            connectionTask = nil
            startAbandonedConnectionCleanup(
                task: connecting.task,
                lease: connecting.lease,
                cancellationClose: connecting.cancellationClose,
                cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
                lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
            )
            return
        }
        connectionTask = nil
        recordConnectCancellation(connecting, reason: .requestCancelled)
        connecting.task.cancel()
        startAbandonedConnectionCleanup(
            task: connecting.task,
            lease: connecting.lease,
            cancellationClose: connecting.cancellationClose,
            cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
            lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
        )
    }
    private func timeoutConnectingWaiter(id connectionID: UUID, waiterID: UUID) async {
        guard transport == nil,
              let connecting = connectionTask,
              connecting.id == connectionID else {
            return
        }
        connectionTask?.waiters.remove(waiterID)
        guard connectionTask?.waiters.isEmpty == true else { return }
        if connecting.completed {
            connectionTask = nil
            startAbandonedConnectionCleanup(
                task: connecting.task,
                lease: connecting.lease,
                cancellationClose: connecting.cancellationClose,
                cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
                lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
            )
            return
        }
        connectionTask = nil
        recordConnectCancellation(connecting, reason: .requestTimedOut)
        connecting.task.cancel()
        startAbandonedConnectionCleanup(
            task: connecting.task,
            lease: connecting.lease,
            cancellationClose: connecting.cancellationClose,
            cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
            lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
        )
    }

    private func markConnectingCompleted(id connectionID: UUID) {
        guard connectionTask?.id == connectionID else { return }
        if let current = connectionTask {
            connectionTask = (
                id: current.id,
                lease: current.lease,
                task: current.task,
                cancellationClose: current.cancellationClose,
                diagnosticAttemptID: current.diagnosticAttemptID,
                diagnosticStartedAt: current.diagnosticStartedAt,
                waiters: current.waiters,
                completed: true
            )
        }
    }

    private func recordConnectCancellation(
        _ connecting: ConnectingTask,
        reason: DiagnosticCancellationReason
    ) {
        guard let attemptID = connecting.diagnosticAttemptID,
              let diagnosticTransport,
              let transportConnectObserver,
              recordedConnectCancellationAttemptIDs.insert(attemptID).inserted
        else { return }
        transportConnectObserver(.cancelled(
            attemptID: attemptID,
            transport: diagnosticTransport,
            reason: reason,
            elapsedMilliseconds: Self.elapsedMilliseconds(
                since: connecting.diagnosticStartedAt ?? ContinuousClock.now
            )
        ))
    }

    private func writeLoop(
        transport: any CmxByteTransport,
        connectionID: UUID,
        frames: AsyncStream<PendingWrite>
    ) async {
        for await write in frames {
            if Task.isCancelled { return }
            guard shouldSendQueuedWrite(write) else {
                continue
            }
            let sendTask = Task {
                try await transport.send(write.frame)
            }
            activeWrite = ActiveWrite(
                connectionID: connectionID,
                requestID: write.requestID,
                task: sendTask
            )
            do {
                try await sendTask.value
                clearActiveWrite(
                    connectionID: connectionID,
                    requestID: write.requestID
                )
            } catch {
                clearActiveWrite(
                    connectionID: connectionID,
                    requestID: write.requestID
                )
                await tearDownIfInstalled(
                    connectionID: connectionID,
                    error: .connectionClosed
                )
                return
            }
        }
    }

    private func readLoop(
        transport: any CmxByteTransport,
        connectionID: UUID
    ) async {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk: Data?
            do {
                chunk = try await transport.receive()
            } catch {
                await tearDownIfInstalled(
                    connectionID: connectionID,
                    error: .connectionClosed
                )
                return
            }
            guard let chunk, !chunk.isEmpty else {
                if chunk == nil {
                    await tearDownIfInstalled(
                        connectionID: connectionID,
                        error: .connectionClosed
                    )
                    return
                }
                continue
            }
            guard !Task.isCancelled,
                  installedConnectionID == connectionID else {
                return
            }
            guard chunk.count <= Self.maximumReceiveBufferByteCount - buffer.count else {
                await tearDownIfInstalled(
                    connectionID: connectionID,
                    error: .invalidResponse
                )
                return
            }
            buffer.append(chunk)
            let frames: [Data]
            do {
                frames = try MobileSyncFrameCodec.decodeFrames(
                    from: &buffer,
                    maximumDecodedFrameCount: Self.maximumDecodedFrameCountPerRead
                )
            } catch {
                await tearDownIfInstalled(
                    connectionID: connectionID,
                    error: .invalidResponse
                )
                return
            }
            for frame in frames {
                dispatch(frame: frame)
            }
        }
    }

    private func failPending(requestID: String, error: MobileShellConnectionError) {
        settlePendingRequest(
            requestID: requestID,
            settlement: .response(.failure(error))
        )
    }
    func cancelPendingRequest(requestID: String) async {
        let legacyContinuation = pending.removeValue(forKey: requestID)
        let pipelinedSettlement = pipelinedPending.removeValue(
            forKey: requestID
        )
        let pipelinedContinuation: PendingContinuation?
        if case let .awaiting(continuation) = pipelinedSettlement {
            pipelinedContinuation = continuation
        } else {
            pipelinedContinuation = nil
        }
        guard legacyContinuation != nil || pipelinedSettlement != nil else {
            return
        }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        if let queuedWriteID = queuedWriteIDs.removeValue(forKey: requestID) {
            cancelledQueuedWriteIDs.insert(queuedWriteID)
        }
        startCancelledActiveWriteResolution(requestID: requestID)
        legacyContinuation?.resume(returning: .cancelled)
        pipelinedContinuation?.resume(returning: .cancelled)
    }

    private func timeoutPendingRequest(requestID: String) async {
        let legacyContinuation = pending.removeValue(forKey: requestID)
        let pipelinedSettlement = pipelinedPending.removeValue(
            forKey: requestID
        )
        guard legacyContinuation != nil || pipelinedSettlement != nil else {
            return
        }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        var condemnedWriteRequestID = requestID
        if let queuedWriteID = queuedWriteIDs.removeValue(forKey: requestID) {
            cancelledQueuedWriteIDs.insert(queuedWriteID)
            // A queued request dying head-of-line blocked behind a cancelled
            // unresolved write is unserved demand: condemn that write now.
            // Its timeout must not merely erase it from `queuedWriteIDs`,
            // where the grace watchdog would mistake it for an explicit
            // cancellation and preserve the wedged transport.
            if let write = activeWrite,
               write.cancelledRequestResolutionTask != nil {
                condemnedWriteRequestID = write.requestID
            }
        }
        let error: MobileShellConnectionError = if await recycleTransportIfActiveWrite(
            requestID: condemnedWriteRequestID
        ) {
            .transportWriteTimedOut
        } else {
            .requestTimedOut
        }
        let settlement = PendingRequestSettlement.response(.failure(error))
        legacyContinuation?.resume(returning: settlement)
        switch pipelinedSettlement {
        case .pending:
            pipelinedPending[requestID] = .settled(settlement)
        case let .awaiting(continuation):
            continuation.resume(returning: settlement)
        case .settled, nil:
            break
        }
    }

    private func shouldSendQueuedWrite(_ write: PendingWrite) -> Bool {
        if cancelledQueuedWriteIDs.remove(write.id) != nil {
            return false
        }
        guard queuedWriteIDs[write.requestID] == write.id else {
            return false
        }
        queuedWriteIDs[write.requestID] = nil
        let hasPipelinedRequestAwaitingResponse: Bool
        switch pipelinedPending[write.requestID] {
        case .pending, .awaiting:
            hasPipelinedRequestAwaitingResponse = true
        case .settled, nil:
            hasPipelinedRequestAwaitingResponse = false
        }
        return pending[write.requestID] != nil
            || hasPipelinedRequestAwaitingResponse
    }

    private func armResponseTimeout(
        requestID: String,
        timeoutNanoseconds: UInt64
    ) {
        requestTimeoutTasks[requestID]?.cancel()
        requestTimeoutTasks[requestID] = Task { [weak self, taskTimeout] in
            do {
                try await taskTimeout.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            await self.timeoutPendingRequest(requestID: requestID)
        }
    }

    func settlePendingRequest(
        requestID: String,
        settlement: PendingRequestSettlement
    ) {
        if let continuation = pending.removeValue(forKey: requestID) {
            requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            continuation.resume(returning: settlement)
            return
        }
        switch pipelinedPending[requestID] {
        case .pending:
            requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            pipelinedPending[requestID] = .settled(settlement)
        case let .awaiting(continuation):
            requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            pipelinedPending.removeValue(forKey: requestID)
            continuation.resume(returning: settlement)
        case .settled, nil:
            break
        }
    }

    private func clearActiveWrite(connectionID: UUID, requestID: String) {
        guard activeWrite?.connectionID == connectionID,
              activeWrite?.requestID == requestID else { return }
        activeWrite = nil
        // Resume coalesced waiters only on a real transition of the CURRENT
        // write: a stale completion callback from an older write generation
        // must not satisfy the recovery gate or the queued-demand watchdog
        // for a newer cancelled write.
        resumeWriteResolutionWaiters()
    }

    private func startCancelledActiveWriteResolution(requestID: String) {
        guard var write = activeWrite,
              write.requestID == requestID,
              write.cancelledRequestResolutionTask == nil else { return }
        let connectionID = write.connectionID
        let sendTask = write.task
        let resolutionTask = Task { [weak self] in
            do {
                try await sendTask.value
                await self?.cancelledActiveWriteDidComplete(
                    connectionID: connectionID,
                    requestID: requestID
                )
            } catch {
                await self?.cancelledActiveWriteDidFail(
                    connectionID: connectionID,
                    requestID: requestID
                )
            }
        }
        write.cancelledRequestResolutionTask = resolutionTask
        activeWrite = write
        startQueuedDemandRecovery(requestID: requestID)
    }

    /// Requests already queued behind the cancelled write have passed the
    /// `send()` recovery gate, so without this watchdog a stalled cancelled
    /// write would block them until their own deadlines and even then leave
    /// the wedged transport installed (their timeout cannot recycle a write
    /// owned by another request ID).
    private func startQueuedDemandRecovery(requestID: String) {
        guard !queuedWriteIDs.isEmpty else { return }
        Task { [self, taskTimeout, cancelledWriteCompletionGraceNanoseconds] in
            let waitTask = Task<Void, any Error> {
                await self.awaitCancelledWriteResolution()
            }
            do {
                try await taskTimeout.value(
                    waitTask,
                    timeoutNanoseconds: cancelledWriteCompletionGraceNanoseconds
                )
            } catch {
                waitTask.cancel()
                await self.recycleCancelledActiveWriteForQueuedDemand(
                    requestID: requestID
                )
            }
        }
    }

    private func recycleCancelledActiveWriteForQueuedDemand(
        requestID: String
    ) async {
        // Re-check demand at grace expiry: if every queued request was
        // cancelled meanwhile, preserve the transport like the no-demand path.
        guard !queuedWriteIDs.isEmpty else { return }
        _ = await recycleTransportIfActiveWrite(requestID: requestID)
    }

    private func waitForCancelledActiveWriteResolution(
        deadlineUptimeNanoseconds: UInt64
    ) async throws {
        while let write = activeWrite,
              write.cancelledRequestResolutionTask != nil {
            try Task.checkCancellation()
            let remainingNanoseconds: UInt64
            do {
                remainingNanoseconds = try taskTimeout.remainingNanoseconds(
                    until: deadlineUptimeNanoseconds
                )
            } catch MobileShellConnectionError.requestTimedOut {
                _ = await recycleTransportIfActiveWrite(
                    requestID: write.requestID
                )
                throw MobileShellConnectionError.requestTimedOut
            }
            let waitTask = Task<Void, any Error> {
                await self.awaitCancelledWriteResolution()
            }
            do {
                try await taskTimeout.value(
                    waitTask,
                    timeoutNanoseconds: min(
                        remainingNanoseconds,
                        cancelledWriteCompletionGraceNanoseconds
                    )
                )
            } catch is CancellationError {
                waitTask.cancel()
                throw CancellationError()
            } catch MobileShellConnectionError.requestTimedOut {
                waitTask.cancel()
                let deadlineExpired =
                    (try? taskTimeout.remainingNanoseconds(
                        until: deadlineUptimeNanoseconds
                    )) == nil
                _ = await recycleTransportIfActiveWrite(
                    requestID: write.requestID
                )
                if deadlineExpired {
                    throw MobileShellConnectionError.requestTimedOut
                }
            }
        }
        try Task.checkCancellation()
    }

    /// Suspends until the cancelled active write completes, fails, or is
    /// recycled. Waiters are coalesced on this actor and resumed by those
    /// resolution events — or unregistered by their own cancellation — so an
    /// abandoned wait never strands a task or continuation parked on the
    /// stalled send itself.
    private func awaitCancelledWriteResolution() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard activeWrite?.cancelledRequestResolutionTask != nil,
                      !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                writeResolutionWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelWriteResolutionWaiter(waiterID) }
        }
    }

    private func cancelWriteResolutionWaiter(_ waiterID: UUID) {
        writeResolutionWaiters.removeValue(forKey: waiterID)?.resume()
    }

    private func resumeWriteResolutionWaiters() {
        guard !writeResolutionWaiters.isEmpty else { return }
        let waiters = writeResolutionWaiters
        writeResolutionWaiters.removeAll()
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    private func cancelledActiveWriteDidComplete(
        connectionID: UUID,
        requestID: String
    ) {
        clearActiveWrite(connectionID: connectionID, requestID: requestID)
    }

    private func cancelledActiveWriteDidFail(
        connectionID: UUID,
        requestID: String
    ) async {
        guard activeWrite?.connectionID == connectionID,
              activeWrite?.requestID == requestID else { return }
        activeWrite = nil
        resumeWriteResolutionWaiters()
        await tearDownIfInstalled(
            connectionID: connectionID,
            error: .connectionClosed
        )
    }

    private func recycleTransportIfActiveWrite(requestID: String) async -> Bool {
        guard activeWrite?.requestID == requestID else { return false }
        activeWrite?.task.cancel()
        activeWrite?.cancelledRequestResolutionTask?.cancel()
        activeWrite = nil
        resumeWriteResolutionWaiters()
        await tearDown(error: .connectionClosed)
        return true
    }

    private func tearDownIfInstalled(
        connectionID: UUID,
        error: MobileShellConnectionError
    ) async {
        guard installedConnectionID == connectionID else { return }
        await tearDown(error: error)
    }

    /// Detaches one installed transport close from session request handling and
    /// transfers its exact task to the shared physical-resource registry.
    private func enqueueTransportClose(
        _ transport: any CmxByteTransport,
        lease: MobileRPCConnectAttemptLease?
    ) async {
        let taskID = UUID()
        let closeTask = Task.detached { [weak self] in
            await transport.close()
            await self?.transportCloseDidFinish(taskID: taskID)
        }
        transportCloseTasks[taskID] = closeTask
        await connectAttemptRegistry.handOffPhysicalCleanup(
            lease: lease
        ) {
            await closeTask.value
        }
    }

    private func transportCloseDidFinish(taskID: UUID) {
        transportCloseTasks[taskID] = nil
    }
}
