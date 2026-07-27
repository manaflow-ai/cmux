internal import CMUXMobileCore
import Foundation

actor MobileCoreRPCSession {
    typealias TransportFactory = @Sendable () throws -> any CmxByteTransport
    typealias IndependentEventByteStreamFactory = @Sendable () async throws -> CmxIndependentEventByteStream
    typealias ConnectedCandidateHook = @Sendable (_ candidate: any CmxByteTransport) async -> Void
    typealias TransportConnectObserver = @Sendable (MobileRPCTransportConnectEvent) -> Void
    enum PendingRequestSettlement {
        case response(Result<Data, MobileShellConnectionError>)
        case cancelled
    }
    typealias PendingContinuation = CheckedContinuation<PendingRequestSettlement, Never>
    typealias ConnectingTask = (id: UUID, lease: MobileRPCConnectAttemptLease?, task: Task<any CmxByteTransport, any Error>, waiters: Set<UUID>, completed: Bool)
    static let defaultAbandonedConnectCleanupTimeoutNanoseconds: UInt64 = 1_000_000_000
    static let defaultLateAbandonedConnectCloseTimeoutNanoseconds: UInt64 = 5_000_000_000
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

    struct IndependentEventPreparation: Sendable {
        let id: UUID
        let task: Task<CmxIndependentEventByteStream, any Error>
    }

    struct IndependentEventReader: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    let taskTimeout = RPCTaskTimeout()
    private let connectAttemptKey: String?
    let connectAttemptRegistry: MobileRPCConnectAttemptRegistry
    let abandonedConnectCleanupTimeoutNanoseconds: UInt64
    let lateAbandonedConnectCloseTimeoutNanoseconds: UInt64
    private let makeTransport: TransportFactory
    let makeIndependentEventByteStream: IndependentEventByteStreamFactory?
    private let didReceiveConnectedCandidate: ConnectedCandidateHook?
    private let diagnosticTransport: DiagnosticTransportKind?
    private let transportConnectObserver: TransportConnectObserver?
    // The getter is internal so the debug-only release-gate extension can
    // inspect the installed transport. Only this actor's production code can
    // replace it.
    private(set) var transport: (any CmxByteTransport)?
    private var connectionTask: ConnectingTask?
    private var installedConnectionID: UUID?
    private var readerTask: Task<Void, Never>?
    var independentEventPreparation: IndependentEventPreparation?
    var independentEventReader: IndependentEventReader?
    /// Subscription stream IDs that already made their one optional-lane
    /// negotiation attempt during this control-session generation.
    var independentEventSubscriptionStreamIDs: Set<String> = []
    var pending: [String: PendingContinuation] = [:]
    var requestTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var queuedWriteIDs: [String: UUID] = [:]
    private var cancelledQueuedWriteIDs: Set<UUID> = []
    // `internal` so cancellation tests can observe the writer-queue gate via
    // `@testable import` without adding a production debug hook.
    var queuedRequestIDs: Set<String> { Set(queuedWriteIDs.keys) }
    var listeners: [UUID: EventListener] = [:]
    var isTearingDown: Bool = false
    private var writeQueue: AsyncStream<PendingWrite>.Continuation?
    private var writerTask: Task<Void, Never>?
    private var activeWrite: (
        connectionID: UUID,
        requestID: String,
        task: Task<Void, any Error>
    )?
    private var transportCloseTask: Task<Void, Never>?
    private var transportCloseTaskID: UUID?
    private var pendingTransportCloses: [any CmxByteTransport] = []

    init(
        connectAttemptKey: String? = nil,
        connectAttemptRegistry: MobileRPCConnectAttemptRegistry = MobileRPCConnectAttemptRegistry(),
        abandonedConnectCleanupTimeoutNanoseconds: UInt64 = 1_000_000_000,
        lateAbandonedConnectCloseTimeoutNanoseconds: UInt64 = 5_000_000_000,
        makeTransport: @escaping TransportFactory,
        makeIndependentEventByteStream: IndependentEventByteStreamFactory? = nil,
        didReceiveConnectedCandidate: ConnectedCandidateHook? = nil,
        diagnosticTransport: DiagnosticTransportKind? = nil,
        transportConnectObserver: TransportConnectObserver? = nil
    ) {
        self.connectAttemptKey = connectAttemptKey
        self.connectAttemptRegistry = connectAttemptRegistry
        self.abandonedConnectCleanupTimeoutNanoseconds = abandonedConnectCleanupTimeoutNanoseconds
        self.lateAbandonedConnectCloseTimeoutNanoseconds = lateAbandonedConnectCloseTimeoutNanoseconds
        self.makeTransport = makeTransport
        self.makeIndependentEventByteStream = makeIndependentEventByteStream
        self.didReceiveConnectedCandidate = didReceiveConnectedCandidate
        self.diagnosticTransport = diagnosticTransport
        self.transportConnectObserver = transportConnectObserver
    }

    deinit {
        connectionTask?.task.cancel()
        readerTask?.cancel()
        independentEventPreparation?.task.cancel()
        independentEventReader?.task.cancel()
        activeWrite?.task.cancel()
        writerTask?.cancel()
        transportCloseTask?.cancel()
        writeQueue?.finish()
    }

    func send(payload: Data, requestID: String, deadlineUptimeNanoseconds: UInt64) async throws -> Data {
        _ = try await ensureConnected(
            timeoutNanoseconds: try taskTimeout.remainingNanoseconds(until: deadlineUptimeNanoseconds)
        )
        let frame = try MobileSyncFrameCodec.encodeFrame(payload)
        let responseTimeoutNanoseconds = try taskTimeout.remainingNanoseconds(until: deadlineUptimeNanoseconds)

        let settlement: PendingRequestSettlement = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard pending[requestID] == nil, queuedWriteIDs[requestID] == nil else {
                    continuation.resume(returning: .response(.failure(.invalidResponse)))
                    return
                }
                let queuedWriteID = UUID()
                pending[requestID] = continuation
                requestTimeoutTasks[requestID]?.cancel()
                requestTimeoutTasks[requestID] = Task { [weak self, taskTimeout] in
                    do {
                        try await taskTimeout.sleep(nanoseconds: responseTimeoutNanoseconds)
                    } catch {
                        return
                    }
                    guard let self else { return }
                    await self.timeoutPendingRequest(requestID: requestID)
                }
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

    func tearDown(error: MobileShellConnectionError) async {
        guard !isTearingDown else { return }
        isTearingDown = true
        let pendingSnapshot = pending
        pending.removeAll()
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
        let listenerSnapshot = listeners
        listeners.removeAll()
        for (_, listener) in listenerSnapshot {
            listener.continuation.finish()
        }
        writeQueue?.finish()
        writeQueue = nil
        activeWrite?.task.cancel()
        activeWrite = nil
        writerTask?.cancel()
        writerTask = nil
        let connecting = connectionTask
        connecting?.task.cancel()
        connectionTask = nil
        installedConnectionID = nil
        let transportToClose = transport
        transport = nil
        readerTask?.cancel()
        readerTask = nil
        independentEventPreparation?.task.cancel()
        independentEventPreparation = nil
        independentEventReader?.task.cancel()
        independentEventReader = nil
        independentEventSubscriptionStreamIDs.removeAll()
        if let transportToClose {
            enqueueTransportClose(transportToClose)
        }
        if let connecting { await abandonConnectionTask(connecting) }
        isTearingDown = false
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
        // One active close plus one queued close is the cleanup capacity. A
        // non-cooperative close can delay one later recovery, but cannot retain
        // an unbounded chain of transports.
        guard pendingTransportCloses.isEmpty else {
            throw MobileShellConnectionError.connectionClosed
        }

        let waiterID = UUID()
        let connectionID: UUID
        let connectLease: MobileRPCConnectAttemptLease?
        let task: Task<any CmxByteTransport, any Error>
        if let existing = connectionTask {
            connectionID = existing.id
            connectLease = existing.lease
            task = existing.task
            connectionTask?.waiters.insert(waiterID)
        } else {
            if let connectAttemptKey {
                guard let lease = await connectAttemptRegistry.beginConnect(key: connectAttemptKey) else {
                    throw MobileShellConnectionError.requestTimedOut
                }
                connectLease = lease
            } else {
                connectLease = .untracked
            }
            let connectAttemptID = Int.random(in: 1...Int.max)
            let connectStartedAt = ContinuousClock.now
            let diagnosticTransport = diagnosticTransport
            let transportConnectObserver = transportConnectObserver
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
            } catch {
                await connectAttemptRegistry.clearFinishedConnect(lease: connectLease)
                if error is CancellationError || Task.isCancelled {
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
            task = Task.detached {
                do {
                    try await withTaskCancellationHandler {
                        try await candidate.connect()
                    } onCancel: {
                        Task {
                            await candidate.close()
                        }
                    }
                    // A cancellation-ignoring transport must still return its
                    // late candidate to the existing abandoned-connect cleanup
                    // path so that path can close it again after completion.
                    // Suppress the success event without replacing that result
                    // with `CancellationError`.
                    if !Task.isCancelled,
                       let diagnosticTransport,
                       let transportConnectObserver {
                        transportConnectObserver(
                            .connected(
                                attemptID: connectAttemptID,
                                transport: diagnosticTransport,
                                elapsedMilliseconds: Self.elapsedMilliseconds(
                                    since: connectStartedAt
                                )
                            )
                        )
                    }
                    return candidate
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Some transports surface their close error instead of
                    // `CancellationError` after the cancellation handler closes
                    // them. Treat the task's cancellation bit as authoritative
                    // so an abandoned dial never becomes a false failure event.
                    if Task.isCancelled {
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
            }
            connectionTask = (id: connectionID, lease: connectLease, task: task, waiters: [waiterID], completed: false)
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
                    await connectAttemptRegistry.clearFinishedConnect(lease: connectLease)
                }
            } else if connectionTask?.id == connectionID {
                connectionTask = nil
                await connectAttemptRegistry.clearFinishedConnect(lease: connectLease)
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

        await connectAttemptRegistry.recordSuccessfulConnect(lease: connectLease)
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
        guard transport == nil, connectionTask?.id == connectionID, let task = connectionTask?.task else {
            return
        }
        connectionTask?.waiters.remove(waiterID)
        guard connectionTask?.waiters.isEmpty == true else { return }
        let lease = connectionTask?.lease
        if connectionTask?.completed == true {
            connectionTask = nil
            startAbandonedConnectionCleanup(
                task: task,
                lease: lease,
                tracksRouteGate: true,
                cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
                lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
            )
            return
        }
        connectionTask = nil
        task.cancel()
        await connectAttemptRegistry.markAbandoned(lease: lease)
        startAbandonedConnectionCleanup(
            task: task,
            lease: lease,
            tracksRouteGate: true,
            cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
            lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
        )
    }
    private func timeoutConnectingWaiter(id connectionID: UUID, waiterID: UUID) async {
        guard transport == nil, connectionTask?.id == connectionID, let task = connectionTask?.task else {
            return
        }
        connectionTask?.waiters.remove(waiterID)
        guard connectionTask?.waiters.isEmpty == true else { return }
        let lease = connectionTask?.lease
        if connectionTask?.completed == true {
            connectionTask = nil
            startAbandonedConnectionCleanup(
                task: task,
                lease: lease,
                tracksRouteGate: true,
                cleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
                lateCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds
            )
            return
        }
        connectionTask = nil
        task.cancel()
        await connectAttemptRegistry.markAbandoned(lease: lease)
        startAbandonedConnectionCleanup(
            task: task,
            lease: lease,
            tracksRouteGate: true,
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
                waiters: current.waiters,
                completed: true
            )
        }
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
            activeWrite = (connectionID, write.requestID, sendTask)
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
        guard let cont = pending.removeValue(forKey: requestID) else { return }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        cont.resume(returning: .response(.failure(error)))
    }
    private func cancelPendingRequest(requestID: String) async {
        guard let cont = pending.removeValue(forKey: requestID) else { return }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        if let queuedWriteID = queuedWriteIDs.removeValue(forKey: requestID) {
            cancelledQueuedWriteIDs.insert(queuedWriteID)
        }
        _ = await recycleTransportIfActiveWrite(requestID: requestID)
        cont.resume(returning: .cancelled)
    }

    private func timeoutPendingRequest(requestID: String) async {
        guard let cont = pending.removeValue(forKey: requestID) else { return }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        if let queuedWriteID = queuedWriteIDs.removeValue(forKey: requestID) {
            cancelledQueuedWriteIDs.insert(queuedWriteID)
        }
        let error: MobileShellConnectionError = if await recycleTransportIfActiveWrite(
            requestID: requestID
        ) {
            .transportWriteTimedOut
        } else {
            .requestTimedOut
        }
        cont.resume(returning: .response(.failure(error)))
    }

    private func shouldSendQueuedWrite(_ write: PendingWrite) -> Bool {
        if cancelledQueuedWriteIDs.remove(write.id) != nil {
            return false
        }
        guard queuedWriteIDs[write.requestID] == write.id else {
            return false
        }
        queuedWriteIDs[write.requestID] = nil
        return pending[write.requestID] != nil
    }

    private func clearActiveWrite(connectionID: UUID, requestID: String) {
        guard activeWrite?.connectionID == connectionID,
              activeWrite?.requestID == requestID else { return }
        activeWrite = nil
    }

    private func recycleTransportIfActiveWrite(requestID: String) async -> Bool {
        guard activeWrite?.requestID == requestID else { return false }
        activeWrite?.task.cancel()
        activeWrite = nil
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

    /// Serializes physical transport cleanup off this actor. Session state is
    /// already detached, so a hanging close cannot block the replacement dial.
    private func enqueueTransportClose(_ transport: any CmxByteTransport) {
        guard transportCloseTask == nil else {
            pendingTransportCloses.append(transport)
            return
        }
        let taskID = UUID()
        transportCloseTaskID = taskID
        transportCloseTask = Task.detached { [weak self] in
            await transport.close()
            await self?.transportCloseDidFinish(taskID: taskID)
        }
    }

    private func transportCloseDidFinish(taskID: UUID) {
        guard transportCloseTaskID == taskID else { return }
        transportCloseTask = nil
        transportCloseTaskID = nil
        guard !pendingTransportCloses.isEmpty else { return }
        let nextTransport = pendingTransportCloses.removeFirst()
        enqueueTransportClose(nextTransport)
    }
}
