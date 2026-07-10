internal import CMUXMobileCore
import Foundation

actor MobileCoreRPCSession {
    typealias TransportFactory = @Sendable () throws -> any CmxByteTransport
    typealias IndependentEventByteStreamFactory = @Sendable () async throws -> CmxIndependentEventByteStream
    typealias ConnectedCandidateHook = @Sendable (_ candidate: any CmxByteTransport) async -> Void
    typealias PendingContinuation = CheckedContinuation<Result<Data, MobileShellConnectionError>, Never>
    typealias ConnectingTask = (id: UUID, lease: MobileRPCConnectAttemptLease?, task: Task<any CmxByteTransport, any Error>, waiters: Set<UUID>, completed: Bool)
    static let defaultAbandonedConnectCleanupTimeoutNanoseconds: UInt64 = 1_000_000_000
    static let defaultLateAbandonedConnectCloseTimeoutNanoseconds: UInt64 = 5_000_000_000
    private static let maximumReceiveBufferByteCount =
        MobileSyncFrameCodec.defaultMaximumFrameByteCount
        + MobileSyncFrameCodec.headerByteCount
    private static let maximumDecodedFrameCountPerRead = 256

    struct EventSubscription {
        let id: UUID
        let stream: AsyncStream<MobileEventEnvelope>
    }

    private struct EventListener {
        let topics: Set<String>
        let continuation: AsyncStream<MobileEventEnvelope>.Continuation
    }

    private struct PendingWrite: Sendable {
        let id: UUID
        let requestID: String
        let frame: Data
    }

    private struct IndependentEventPreparation: Sendable {
        let id: UUID
        let task: Task<CmxIndependentEventByteStream, any Error>
    }

    private struct IndependentEventReader: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let taskTimeout = RPCTaskTimeout()
    private let connectAttemptKey: String?
    let connectAttemptRegistry: MobileRPCConnectAttemptRegistry
    let abandonedConnectCleanupTimeoutNanoseconds: UInt64
    let lateAbandonedConnectCloseTimeoutNanoseconds: UInt64
    private let makeTransport: TransportFactory
    private let makeIndependentEventByteStream: IndependentEventByteStreamFactory?
    private let didReceiveConnectedCandidate: ConnectedCandidateHook?
    private var transport: (any CmxByteTransport)?
    private var connectionTask: ConnectingTask?
    private var installedConnectionID: UUID?
    private var readerTask: Task<Void, Never>?
    private var independentEventPreparation: IndependentEventPreparation?
    private var independentEventReader: IndependentEventReader?
    private var pending: [String: PendingContinuation] = [:]
    private var requestTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var queuedWriteIDs: [String: UUID] = [:]
    private var cancelledQueuedWriteIDs: Set<UUID> = []
    // `internal` so cancellation tests can observe the writer-queue gate via
    // `@testable import` without adding a production debug hook.
    var queuedRequestIDs: Set<String> { Set(queuedWriteIDs.keys) }
    private var listeners: [UUID: EventListener] = [:]
    private var isTearingDown: Bool = false
    private var writeQueue: AsyncStream<PendingWrite>.Continuation?
    private var writerTask: Task<Void, Never>?

    init(
        connectAttemptKey: String? = nil,
        connectAttemptRegistry: MobileRPCConnectAttemptRegistry = MobileRPCConnectAttemptRegistry(),
        abandonedConnectCleanupTimeoutNanoseconds: UInt64 = 1_000_000_000,
        lateAbandonedConnectCloseTimeoutNanoseconds: UInt64 = 5_000_000_000,
        makeTransport: @escaping TransportFactory,
        makeIndependentEventByteStream: IndependentEventByteStreamFactory? = nil,
        didReceiveConnectedCandidate: ConnectedCandidateHook? = nil
    ) {
        self.connectAttemptKey = connectAttemptKey
        self.connectAttemptRegistry = connectAttemptRegistry
        self.abandonedConnectCleanupTimeoutNanoseconds = abandonedConnectCleanupTimeoutNanoseconds
        self.lateAbandonedConnectCloseTimeoutNanoseconds = lateAbandonedConnectCloseTimeoutNanoseconds
        self.makeTransport = makeTransport
        self.makeIndependentEventByteStream = makeIndependentEventByteStream
        self.didReceiveConnectedCandidate = didReceiveConnectedCandidate
    }

    deinit {
        connectionTask?.task.cancel()
        readerTask?.cancel()
        independentEventPreparation?.task.cancel()
        independentEventReader?.task.cancel()
        writerTask?.cancel()
        writeQueue?.finish()
    }

    func send(payload: Data, requestID: String, deadlineUptimeNanoseconds: UInt64) async throws -> Data {
        _ = try await ensureConnected(
            timeoutNanoseconds: try taskTimeout.remainingNanoseconds(until: deadlineUptimeNanoseconds)
        )
        let frame = try MobileSyncFrameCodec.encodeFrame(payload)
        let responseTimeoutNanoseconds = try taskTimeout.remainingNanoseconds(until: deadlineUptimeNanoseconds)

        let result: Result<Data, MobileShellConnectionError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard pending[requestID] == nil, queuedWriteIDs[requestID] == nil else {
                    continuation.resume(returning: .failure(.invalidResponse))
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
                    continuation.resume(returning: .failure(.connectionClosed))
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
        if Task.isCancelled {
            throw CancellationError()
        }
        switch result {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    func addEventListener(topics: Set<String>) -> EventSubscription {
        let id = UUID()
        var continuation: AsyncStream<MobileEventEnvelope>.Continuation!
        let stream = AsyncStream<MobileEventEnvelope>(bufferingPolicy: .bufferingNewest(256)) { cont in
            continuation = cont
        }
        listeners[id] = EventListener(topics: topics, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeListener(id: id) }
        }
        return EventSubscription(id: id, stream: stream)
    }

    func removeListener(id: UUID) {
        listeners.removeValue(forKey: id)
    }

    /// Prepares one independently framed server-event reader when the active
    /// route supports it. Concurrent callers coalesce onto the same provider
    /// operation and never create competing stream consumers.
    func prepareIndependentServerEvents(
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        if independentEventReader != nil { return true }
        guard !isTearingDown, let makeIndependentEventByteStream else { return false }

        let preparation: IndependentEventPreparation
        if let current = independentEventPreparation {
            preparation = current
        } else {
            let task = Task {
                try await makeIndependentEventByteStream()
            }
            preparation = IndependentEventPreparation(id: UUID(), task: task)
            independentEventPreparation = preparation
        }

        do {
            let stream: CmxIndependentEventByteStream
            if let timeoutNanoseconds {
                stream = try await taskTimeout.value(
                    preparation.task,
                    timeoutNanoseconds: timeoutNanoseconds
                )
            } else {
                stream = try await preparation.task.value
            }
            guard independentEventPreparation?.id == preparation.id else {
                return independentEventReader != nil
            }
            independentEventPreparation = nil
            guard !isTearingDown else { return false }
            if independentEventReader != nil { return true }

            let readerID = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.readIndependentEventLoop(stream: stream, id: readerID)
            }
            independentEventReader = IndependentEventReader(id: readerID, task: task)
            return true
        } catch MobileShellConnectionError.requestTimedOut {
            // The optional preparation does not consume the control RPC's full
            // deadline. Keep the shared provider operation alive so a later
            // subscribe can adopt it, while this request uses control fallback.
            return independentEventReader != nil
        } catch is CancellationError {
            return independentEventReader != nil
        } catch {
            if independentEventPreparation?.id == preparation.id {
                independentEventPreparation = nil
            }
            return independentEventReader != nil
        }
    }

    func connectWaiterCountForTesting() -> Int { connectionTask?.waiters.count ?? 0 }
    var hasIndependentEventReaderForTesting: Bool { independentEventReader != nil }
    var eventListenerCountForTesting: Int { listeners.count }

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
            cont.resume(returning: .failure(error))
        }
        let listenerSnapshot = listeners
        listeners.removeAll()
        for (_, listener) in listenerSnapshot {
            listener.continuation.finish()
        }
        writeQueue?.finish()
        writeQueue = nil
        writerTask?.cancel()
        writerTask = nil
        let connecting = connectionTask
        connecting?.task.cancel()
        connectionTask = nil
        installedConnectionID = nil
        if let transport {
            await transport.close()
        }
        transport = nil
        readerTask?.cancel()
        readerTask = nil
        independentEventPreparation?.task.cancel()
        independentEventPreparation = nil
        independentEventReader?.task.cancel()
        independentEventReader = nil
        if let connecting { await abandonConnectionTask(connecting) }
        isTearingDown = false
    }

    // MARK: - private

    private func ensureConnected(timeoutNanoseconds: UInt64) async throws -> any CmxByteTransport {
        if let transport { return transport }

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
            let candidate: any CmxByteTransport
            do {
                candidate = try makeTransport()
            } catch {
                await connectAttemptRegistry.clearFinishedConnect(lease: connectLease)
                throw error
            }
            connectionID = UUID()
            task = Task.detached {
                try await withTaskCancellationHandler {
                    try await candidate.connect()
                    return candidate
                } onCancel: {
                    Task {
                        await candidate.close()
                    }
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

        connectionTask = nil
        installedConnectionID = connectionID
        transport = candidate
        await connectAttemptRegistry.recordSuccessfulConnect(lease: connectLease)
        readerTask = Task { [weak self] in
            await self?.readLoop(transport: candidate)
        }
        let (stream, continuation) = AsyncStream<PendingWrite>.makeStream(bufferingPolicy: .unbounded)
        writeQueue = continuation
        writerTask = Task { [weak self] in
            await self?.writeLoop(transport: candidate, frames: stream)
        }
        if callerCancelled {
            throw CancellationError()
        }
        return candidate
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

    private func writeLoop(transport: any CmxByteTransport, frames: AsyncStream<PendingWrite>) async {
        for await write in frames {
            if Task.isCancelled { return }
            guard shouldSendQueuedWrite(write) else {
                continue
            }
            do {
                try await transport.send(write.frame)
            } catch {
                await tearDown(error: .connectionClosed)
                return
            }
        }
    }

    private func readLoop(transport: any CmxByteTransport) async {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk: Data?
            do {
                chunk = try await transport.receive()
            } catch {
                await tearDown(error: .connectionClosed)
                return
            }
            guard let chunk, !chunk.isEmpty else {
                if chunk == nil {
                    await tearDown(error: .connectionClosed)
                    return
                }
                continue
            }
            guard chunk.count <= Self.maximumReceiveBufferByteCount - buffer.count else {
                await tearDown(error: .invalidResponse)
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
                await tearDown(error: .invalidResponse)
                return
            }
            for frame in frames {
                dispatch(frame: frame)
            }
        }
    }

    /// Reads only independently framed event bytes. A malformed or closed
    /// event stream disables this optional path without tearing down control
    /// RPCs or finishing their existing event listeners. The next subscribe
    /// reassertion may prepare a fresh event stream and the host can fall back
    /// to control delivery in the meantime.
    private func readIndependentEventLoop(
        stream: CmxIndependentEventByteStream,
        id: UUID
    ) async {
        defer {
            if independentEventReader?.id == id {
                independentEventReader = nil
            }
        }

        var buffer = Data()
        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                guard !chunk.isEmpty else { continue }
                guard chunk.count <= Self.maximumReceiveBufferByteCount - buffer.count else {
                    throw MobileSyncFrameCodecError.frameTooLarge(
                        buffer.count + chunk.count
                    )
                }
                buffer.append(chunk)
                let frames = try MobileSyncFrameCodec.decodeFrames(
                    from: &buffer,
                    maximumDecodedFrameCount: Self.maximumDecodedFrameCountPerRead
                )
                for frame in frames {
                    dispatch(frame: frame)
                }
            }
        } catch {
            // Optional-lane failure deliberately leaves the control session and
            // listener registrations alive for rolling fallback.
        }
    }

    private func dispatch(frame: Data) {
        let parsed = try? JSONSerialization.jsonObject(with: frame) as? [String: Any]
        guard let envelope = parsed else { return }
        if (envelope["kind"] as? String) == "event" {
            guard let topic = envelope["topic"] as? String else { return }
            let payloadData: Data?
            if let payload = envelope["payload"] {
                payloadData = try? JSONSerialization.data(withJSONObject: payload)
            } else {
                payloadData = nil
            }
            let streamID = envelope["stream_id"] as? String
            let event = MobileEventEnvelope(topic: topic, payloadJSON: payloadData, streamID: streamID)
            for (_, listener) in listeners where listener.topics.contains(topic) {
                listener.continuation.yield(event)
            }
            return
        }
        guard let id = envelope["id"] as? String else { return }
        guard let cont = pending.removeValue(forKey: id) else { return }
        requestTimeoutTasks.removeValue(forKey: id)?.cancel()
        if (envelope["ok"] as? Bool) == true {
            let result = envelope["result"] ?? [:]
            if let data = try? JSONSerialization.data(withJSONObject: result) {
                cont.resume(returning: .success(data))
            } else {
                cont.resume(returning: .failure(.invalidResponse))
            }
            return
        }
        let errorPayload = envelope["error"] as? [String: Any]
        let message = (errorPayload?["message"] as? String) ?? "RPC error"
        let code = errorPayload?["code"] as? String
        switch code {
        case "unauthorized":
            cont.resume(returning: .failure(.authorizationFailed(message)))
        case "account_mismatch":
            // The Mac is signed in to a different cmux account. Surface a
            // distinct error so the shell drives a re-auth flow into the owner's
            // account rather than retrying with this account's fresh token.
            cont.resume(returning: .failure(.accountMismatch(message)))
        default:
            cont.resume(returning: .failure(.rpcError(code, message)))
        }
    }

    private func failPending(requestID: String, error: MobileShellConnectionError) {
        guard let cont = pending.removeValue(forKey: requestID) else { return }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        cont.resume(returning: .failure(error))
    }
    private func cancelPendingRequest(requestID: String) {
        guard let cont = pending.removeValue(forKey: requestID) else { return }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        if let queuedWriteID = queuedWriteIDs.removeValue(forKey: requestID) {
            cancelledQueuedWriteIDs.insert(queuedWriteID)
        }
        cont.resume(returning: .failure(.requestTimedOut))
    }

    private func timeoutPendingRequest(requestID: String) {
        guard let cont = pending.removeValue(forKey: requestID) else { return }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        if let queuedWriteID = queuedWriteIDs.removeValue(forKey: requestID) {
            cancelledQueuedWriteIDs.insert(queuedWriteID)
        }
        cont.resume(returning: .failure(.requestTimedOut))
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
}
