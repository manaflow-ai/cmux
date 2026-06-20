internal import CMUXMobileCore
import Foundation

/// Owns a single persistent transport for a ``MobileCoreRPCClient``, multiplexes
/// requests by id, and dispatches server-pushed events to registered listeners.
///
/// No polling: the reader task runs continuously, parking on `transport.receive()`
/// until the kernel delivers bytes. Request deadlines are attached to pending
/// continuations so a hung transport cannot keep the caller waiting forever.
actor MobileCoreRPCSession {
    typealias TransportFactory = @Sendable () throws -> any CmxByteTransport
    typealias ConnectedCandidateHook = @Sendable (_ candidate: any CmxByteTransport) async -> Void
    typealias PendingContinuation = CheckedContinuation<Result<Data, MobileShellConnectionError>, Never>

    struct EventSubscription {
        let id: UUID
        let stream: AsyncStream<MobileEventEnvelope>
    }

    private struct EventListener {
        let topics: Set<String>
        let continuation: AsyncStream<MobileEventEnvelope>.Continuation
    }

    private struct PendingWrite: Sendable {
        let requestID: String
        let frame: Data
    }

    private let taskTimeout = RPCTaskTimeout()
    private let makeTransport: TransportFactory
    private let didReceiveConnectedCandidate: ConnectedCandidateHook?
    private var transport: (any CmxByteTransport)?
    private var connectionTask: (
        id: UUID,
        task: Task<any CmxByteTransport, any Error>,
        waiters: Int,
        timedOut: Bool,
        completed: Bool
    )?
    private var installedConnectionID: UUID?
    private var readerTask: Task<Void, Never>?
    private var pending: [String: PendingContinuation] = [:]
    private var requestTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var queuedRequestIDs: Set<String> = []
    private var cancelledQueuedRequestIDs: Set<String> = []
    private var listeners: [UUID: EventListener] = [:]
    private var isTearingDown: Bool = false
    /// Pending writes drained by `writerTask`. Serializes `transport.send` so
    /// two concurrent `send(payload:requestID:)` callers never trip
    /// `CmxNetworkByteTransport.sendAlreadyInProgress`. AsyncStream backed so
    /// the writer parks on `await` instead of polling.
    private var writeQueue: AsyncStream<PendingWrite>.Continuation?
    private var writerTask: Task<Void, Never>?

    init(
        makeTransport: @escaping TransportFactory,
        didReceiveConnectedCandidate: ConnectedCandidateHook? = nil
    ) {
        self.makeTransport = makeTransport
        self.didReceiveConnectedCandidate = didReceiveConnectedCandidate
    }

    deinit {
        connectionTask?.task.cancel()
        readerTask?.cancel()
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
                // Register BEFORE handing the frame to the writer so a fast
                // response can't race past us. Writer pulls frames serially
                // from `writeQueue`, so concurrent senders never overlap a
                // `transport.send()` call.
                guard pending[requestID] == nil, !queuedRequestIDs.contains(requestID) else {
                    continuation.resume(returning: .failure(.invalidResponse))
                    return
                }
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
                queuedRequestIDs.insert(requestID)
                _ = queue.yield(PendingWrite(requestID: requestID, frame: frame))
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

    func tearDown(error: MobileShellConnectionError) async {
        guard !isTearingDown else { return }
        isTearingDown = true
        let pendingSnapshot = pending
        pending.removeAll()
        let timeoutSnapshot = requestTimeoutTasks
        requestTimeoutTasks.removeAll()
        queuedRequestIDs.removeAll()
        cancelledQueuedRequestIDs.removeAll()
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
        // Stop the writer loop before closing the transport so we don't try to
        // write into a half-closed socket and never trigger
        // sendAlreadyInProgress on a torn-down state.
        writeQueue?.finish()
        writeQueue = nil
        writerTask?.cancel()
        writerTask = nil
        connectionTask?.task.cancel()
        connectionTask = nil
        installedConnectionID = nil
        if let transport {
            await transport.close()
        }
        transport = nil
        readerTask?.cancel()
        readerTask = nil
        isTearingDown = false
    }

    // MARK: - private

    private func ensureConnected(timeoutNanoseconds: UInt64) async throws -> any CmxByteTransport {
        if let transport { return transport }

        let connectionID: UUID
        let task: Task<any CmxByteTransport, any Error>
        if let existing = connectionTask {
            guard !existing.timedOut else {
                throw MobileShellConnectionError.requestTimedOut
            }
            connectionID = existing.id
            task = existing.task
            connectionTask?.waiters += 1
        } else {
            let candidate = try makeTransport()
            connectionID = UUID()
            task = Task {
                try await withTaskCancellationHandler {
                    try await candidate.connect()
                    try Task.checkCancellation()
                    return candidate
                } onCancel: {
                    Task {
                        await candidate.close()
                    }
                }
            }
            connectionTask = (id: connectionID, task: task, waiters: 1, timedOut: false, completed: false)
            Task.detached { [weak self] in
                _ = await task.result
                await self?.markConnectingCompleted(id: connectionID)
            }
        }

        let candidate: any CmxByteTransport
        do {
            if connectionTask?.timedOut == true {
                throw MobileShellConnectionError.requestTimedOut
            }
            let connected = try await taskTimeout.value(task, timeoutNanoseconds: timeoutNanoseconds)
            if let didReceiveConnectedCandidate {
                await didReceiveConnectedCandidate(connected)
            }
            if Task.isCancelled {
                if cancelConnectedWaiter(id: connectionID) {
                    await connected.close()
                }
                throw CancellationError()
            }
            candidate = connected
        } catch {
            if Task.isCancelled {
                // Cancellation before a candidate is returned removes only
                // this caller's waiter slot. If the candidate was returned,
                // the branch above already decided whether this caller was
                // the last owner and closed it only then.
                cancelConnectingWaiter(id: connectionID)
                throw CancellationError()
            }
            if case MobileShellConnectionError.requestTimedOut = error {
                await timeoutConnectingWaiter(id: connectionID)
            } else if error is CancellationError {
                // A shared connection task can surface cancellation after all
                // waiters have timed out/cancelled. Do not clear a replacement
                // connection task that may already be in flight.
            } else if connectionTask?.id == connectionID {
                connectionTask = nil
            }
            throw error
        }

        if let transport {
            if installedConnectionID != connectionID {
                await candidate.close()
            }
            return transport
        }

        guard connectionTask?.id == connectionID else {
            await candidate.close()
            throw MobileShellConnectionError.connectionClosed
        }

        connectionTask = nil
        installedConnectionID = connectionID
        transport = candidate
        // Reader: dispatches inbound frames by id (response) or topic (event).
        readerTask = Task { [weak self] in
            await self?.readLoop(transport: candidate)
        }
        // Writer: drains queued frames one at a time so concurrent send()
        // callers don't trigger CmxNetworkByteTransport.sendAlreadyInProgress.
        // Failures tear the whole session down which fails every pending
        // continuation.
        let (stream, continuation) = AsyncStream<PendingWrite>.makeStream(bufferingPolicy: .unbounded)
        writeQueue = continuation
        writerTask = Task { [weak self] in
            await self?.writeLoop(transport: candidate, frames: stream)
        }
        return candidate
    }

    private func cancelConnectedWaiter(id connectionID: UUID) -> Bool {
        guard transport == nil else {
            return false
        }
        guard connectionTask?.id == connectionID else {
            return true
        }
        connectionTask?.waiters -= 1
        guard let waiters = connectionTask?.waiters, waiters <= 0 else {
            return false
        }
        connectionTask = nil
        return true
    }

    private func cancelConnectingWaiter(id connectionID: UUID) {
        guard transport == nil, connectionTask?.id == connectionID else {
            return
        }
        connectionTask?.waiters -= 1
        guard let waiters = connectionTask?.waiters, waiters <= 0 else {
            return
        }
        connectionTask?.task.cancel()
        connectionTask = nil
    }

    private func timeoutConnectingWaiter(id connectionID: UUID) async {
        guard transport == nil, connectionTask?.id == connectionID, let task = connectionTask?.task else {
            return
        }
        connectionTask?.waiters -= 1
        guard let waiters = connectionTask?.waiters, waiters <= 0 else {
            return
        }
        if connectionTask?.completed == true {
            connectionTask = nil
            if let candidate = try? await task.value {
                await candidate.close()
            }
            return
        }
        connectionTask = (id: connectionID, task: task, waiters: 0, timedOut: true, completed: false)
        task.cancel()
    }

    private func markConnectingCompleted(id connectionID: UUID) {
        guard connectionTask?.id == connectionID else { return }
        if connectionTask?.timedOut == true {
            connectionTask = nil
        } else if let current = connectionTask {
            connectionTask = (
                id: current.id,
                task: current.task,
                waiters: current.waiters,
                timedOut: current.timedOut,
                completed: true
            )
        }
    }

    private func writeLoop(transport: any CmxByteTransport, frames: AsyncStream<PendingWrite>) async {
        for await write in frames {
            if Task.isCancelled { return }
            guard shouldSendQueuedWrite(requestID: write.requestID) else {
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
            buffer.append(chunk)
            let frames: [Data]
            do {
                frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
            } catch {
                await tearDown(error: .invalidResponse)
                return
            }
            for frame in frames {
                dispatch(frame: frame)
            }
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
        if queuedRequestIDs.remove(requestID) != nil {
            cancelledQueuedRequestIDs.insert(requestID)
        }
        cont.resume(returning: .failure(.requestTimedOut))
    }

    private func timeoutPendingRequest(requestID: String) {
        guard let cont = pending.removeValue(forKey: requestID) else { return }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        if queuedRequestIDs.remove(requestID) != nil {
            cancelledQueuedRequestIDs.insert(requestID)
        }
        cont.resume(returning: .failure(.requestTimedOut))
    }

    private func shouldSendQueuedWrite(requestID: String) -> Bool {
        let wasQueued = queuedRequestIDs.remove(requestID) != nil
        if cancelledQueuedRequestIDs.remove(requestID) != nil {
            return false
        }
        return wasQueued && pending[requestID] != nil
    }

}
