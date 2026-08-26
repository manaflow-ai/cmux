@preconcurrency import Foundation

/// Actor-isolated CDP command router over an injected message transport.
actor ChromiumCDPConnection {
    typealias FrameContinuation = AsyncStream<Data>.Continuation

    /// Single-consumer event sequence backed by the actor's bounded queue.
    /// Keeping the queue in the connection lets the receiver prioritize
    /// lifecycle signals and emit one bounded resync marker when noncritical
    /// events are discarded, without relying on `AsyncStream` eviction.
    struct EventStream: AsyncSequence, Sendable {
        typealias Element = CDPEvent

        let connection: ChromiumCDPConnection

        struct Iterator: AsyncIteratorProtocol {
            let connection: ChromiumCDPConnection

            mutating func next() async -> CDPEvent? {
                await connection.nextEvent()
            }
        }

        func makeAsyncIterator() -> Iterator {
            Iterator(connection: connection)
        }
    }

    /// Byte token identifying a screencast frame envelope without parsing it.
    private static let screencastFrameToken = Data("\"method\":\"Page.screencastFrame\"".utf8)
    /// Maximum number of decoded events retained while the single consumer is
    /// awaiting a CDP command response.
    private static let eventBufferCapacity = 512
    private static let resyncEventMethod = "cmux.cdp.resyncRequired"
    private static let priorityEventMethods: Set<String> = [
        "Page.frameStartedLoading",
        "Page.frameStoppedLoading",
        "Page.lifecycleEvent",
        "Page.loadEventFired",
        "Page.crashed",
        "Target.targetCrashed",
        "Target.detachedFromTarget",
        "Inspector.detached",
    ]

    private let transport: any ChromiumCDPTransport
    private var receiverTask: Task<Void, Never>?
    private var nextCommandID = 1
    private var pending: [Int: CheckedContinuation<CDPValue, any Error>] = [:]
    private var activeCommandIDs: Set<Int> = []
    private var cancelledCommandIDs: Set<Int> = []
    private var sendTasks: [Int: Task<Void, Never>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var eventQueue: [CDPEvent] = []
    private var eventWaiter: CheckedContinuation<CDPEvent?, Never>?
    private var eventResyncQueued = false
    private var frameContinuations: [UUID: FrameContinuation] = [:]
    private var activeTargetSessionID: String?
    private var isClosed = false
    private let commandTimeout: Duration

    init(endpoint: URL, session: URLSession, commandTimeout: Duration = .seconds(15)) throws {
        transport = try ChromiumCDPWebSocketTransport(endpoint: endpoint, session: session)
        self.commandTimeout = commandTimeout
    }

    init(transport: any ChromiumCDPTransport, commandTimeout: Duration = .seconds(15)) {
        self.transport = transport
        self.commandTimeout = commandTimeout
    }

    func connect() async throws {
        guard receiverTask == nil else { return }
        isClosed = false
        let messages = transport.messages()
        receiverTask = Task { [weak self] in
            for await result in messages {
                guard !Task.isCancelled else { return }
                await self?.receive(result)
            }
            await self?.transportDidEnd(error: nil)
        }
        do {
            try await transport.connect()
        } catch {
            receiverTask?.cancel()
            receiverTask = nil
            isClosed = true
            await transport.close()
            throw error
        }
    }

    /// Attaches a pipe-level browser connection to its first page target.
    func attachToPageTarget() async throws {
        let targets = try await sendBrowserCommand(method: "Target.getTargets")
        guard case .object(let targetPayload) = targets,
              case .array(let targetInfos)? = targetPayload["targetInfos"],
              let targetID = targetInfos.compactMap(Self.pageTargetID).first else {
            throw CDPError.protocolError(ChromiumBrowserDiagnostic.noPageTarget.message)
        }
        let attachment = try await sendBrowserCommand(
            method: "Target.attachToTarget",
            parameters: .object([
                "targetId": .string(targetID),
                "flatten": .bool(true),
            ])
        )
        guard case .object(let attachmentPayload) = attachment,
              let sessionID = attachmentPayload["sessionId"]?.stringValue,
              !sessionID.isEmpty else {
            throw CDPError.protocolError(ChromiumBrowserDiagnostic.noPageTarget.message)
        }
        activeTargetSessionID = sessionID
    }

    /// Schedules an idempotent close for synchronous lifecycle callbacks.
    nonisolated func close() {
        Task { await shutdown() }
    }

    func events() -> EventStream {
        EventStream(connection: self)
    }

    /// Streams decoded screencast frames without the generic event pipeline.
    ///
    /// Frame envelopes dominate CDP traffic by orders of magnitude; keeping
    /// them out of `events()` keeps command and lifecycle handling responsive
    /// and lets a slow consumer drop to the newest frame instead of queueing.
    func screencastFrames() -> AsyncStream<Data> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            guard !isClosed else {
                continuation.finish()
                return
            }
            frameContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeFrameContinuation(id) }
            }
        }
    }

    func send(method: String, parameters: CDPValue? = nil) async throws -> CDPValue {
        try await send(
            method: method,
            parameters: parameters,
            targetSessionID: activeTargetSessionID
        )
    }

    private func sendBrowserCommand(
        method: String,
        parameters: CDPValue? = nil
    ) async throws -> CDPValue {
        try await send(method: method, parameters: parameters, targetSessionID: nil)
    }

    private func send(
        method: String,
        parameters: CDPValue?,
        targetSessionID: String?
    ) async throws -> CDPValue {
        guard receiverTask != nil, !isClosed else { throw CDPError.notConnected }
        try Task.checkCancellation()
        let id = nextCommandID
        nextCommandID += 1
        activeCommandIDs.insert(id)
        var object: [String: CDPValue] = [
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let parameters {
            object["params"] = parameters
        }
        if let targetSessionID {
            object["sessionId"] = .string(targetSessionID)
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(CDPValue.object(object))
        } catch {
            activeCommandIDs.remove(id)
            throw error
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if isClosed {
                    activeCommandIDs.remove(id)
                    continuation.resume(
                        throwing: CDPError.disconnected(
                            ChromiumBrowserDiagnostic.connectionClosed.message
                        )
                    )
                    return
                }
                if Task.isCancelled || cancelledCommandIDs.remove(id) != nil {
                    activeCommandIDs.remove(id)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                let transport = self.transport
                let sendTask = Task { [weak self] in
                    do {
                        try await transport.send(data)
                    } catch {
                        await self?.sendFailed(
                            id: id,
                            error: CDPError.disconnected(error.localizedDescription)
                        )
                    }
                }
                sendTasks[id] = sendTask
                let timeout = commandTimeout
                timeoutTasks[id] = Task { [weak self, timeout] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.commandTimedOut(id: id)
                }
            }
        }, onCancel: { [weak self] in
            Task { await self?.cancelPending(id: id) }
        })
    }

    func shutdown() async {
        if !isClosed || receiverTask != nil {
            isClosed = true
            receiverTask?.cancel()
            receiverTask = nil
            activeTargetSessionID = nil
            eventQueue.removeAll()
            eventResyncQueued = false
            eventWaiter?.resume(returning: nil)
            eventWaiter = nil
            for task in sendTasks.values { task.cancel() }
            sendTasks.removeAll()
            for task in timeoutTasks.values { task.cancel() }
            timeoutTasks.removeAll()
            let waiters = pending
            pending.removeAll()
            activeCommandIDs.removeAll()
            cancelledCommandIDs.removeAll()
            for waiter in waiters.values {
                waiter.resume(
                    throwing: CDPError.disconnected(ChromiumBrowserDiagnostic.connectionClosed.message)
                )
            }
            for continuation in frameContinuations.values {
                continuation.finish()
            }
            frameContinuations.removeAll()
        }
        // A peer-ended message stream marks the connection closed before the
        // owner calls shutdown. Always forward the idempotent close so the
        // underlying socket or pipe releases its descriptors in that path.
        await transport.close()
    }

    private func nextEvent() async -> CDPEvent? {
        if !eventQueue.isEmpty {
            let event = eventQueue.removeFirst()
            if event.method == Self.resyncEventMethod {
                eventResyncQueued = false
            }
            return event
        }
        guard !isClosed else { return nil }
        return await withCheckedContinuation { continuation in
            eventWaiter = continuation
        }
    }

    private func enqueueEvent(_ event: CDPEvent) {
        if let waiter = eventWaiter {
            eventWaiter = nil
            waiter.resume(returning: event)
            return
        }

        guard eventQueue.count < Self.eventBufferCapacity else {
            if Self.priorityEventMethods.contains(event.method) {
                var evictedNormalEvent = false
                if let evictIndex = eventQueue.firstIndex(where: {
                    !Self.priorityEventMethods.contains($0.method) &&
                        $0.method != Self.resyncEventMethod
                }) {
                    eventQueue.remove(at: evictIndex)
                    evictedNormalEvent = true
                    eventQueue.append(event)
                } else if let evictIndex = eventQueue.firstIndex(where: {
                    $0.method != Self.resyncEventMethod
                }) {
                    eventQueue.remove(at: evictIndex)
                    eventQueue.append(event)
                }
                if evictedNormalEvent, !eventResyncQueued {
                    eventResyncQueued = true
                    while eventQueue.count >= Self.eventBufferCapacity {
                        guard let evictIndex = eventQueue.firstIndex(where: {
                            $0.method != Self.resyncEventMethod
                        }) else { break }
                        eventQueue.remove(at: evictIndex)
                    }
                    if eventQueue.count < Self.eventBufferCapacity {
                        eventQueue.append(CDPEvent(method: Self.resyncEventMethod))
                    }
                }
                return
            }

            guard !eventResyncQueued else { return }
            eventResyncQueued = true
            // The queued normal events are older than the state we are about
            // to re-read. Discard them at the resync boundary so they cannot
            // replay stale URLs/loading state after the authoritative refresh.
            eventQueue.removeAll {
                !Self.priorityEventMethods.contains($0.method) &&
                    $0.method != Self.resyncEventMethod
            }
            while eventQueue.count >= Self.eventBufferCapacity {
                guard let evictIndex = eventQueue.firstIndex(where: {
                    $0.method != Self.resyncEventMethod
                }) else { break }
                eventQueue.remove(at: evictIndex)
            }
            if eventQueue.count < Self.eventBufferCapacity {
                eventQueue.append(CDPEvent(method: Self.resyncEventMethod))
            }
            return
        }
        eventQueue.append(event)
    }

    private func removeFrameContinuation(_ id: UUID) {
        frameContinuations.removeValue(forKey: id)
    }

    private func commandTimedOut(id: Int) {
        guard activeCommandIDs.contains(id) else { return }
        failPending(id: id, error: ChromiumBrowserDiagnostic.commandTimedOut)
    }

    /// Handles one screencast envelope. Returns `false` when the payload is
    /// not actually a well-formed frame, in which case the caller falls back
    /// to the generic decoder.
    private func handleScreencastFrame(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["method"] as? String == "Page.screencastFrame",
              let params = object["params"] as? [String: Any] else {
            return false
        }
        if let activeTargetSessionID {
            // Frames for a foreign target are consumed, never acked: the same
            // filter the generic event path applies.
            guard object["sessionId"] as? String == activeTargetSessionID else { return true }
        }
        if let ackSessionID = (params["sessionId"] as? NSNumber)?.doubleValue {
            Task { [weak self] in
                _ = try? await self?.send(
                    method: "Page.screencastFrameAck",
                    parameters: .object(["sessionId": .number(ackSessionID)])
                )
            }
        }
        guard let encoded = params["data"] as? String,
              let frame = Data(base64Encoded: encoded) else {
            return true
        }
        for continuation in frameContinuations.values {
            continuation.yield(frame)
        }
        return true
    }

    private func cancelPending(id: Int) {
        guard activeCommandIDs.contains(id) else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        sendTasks[id]?.cancel()
        sendTasks.removeValue(forKey: id)
        guard let continuation = pending.removeValue(forKey: id) else {
            cancelledCommandIDs.insert(id)
            return
        }
        activeCommandIDs.remove(id)
        continuation.resume(throwing: CancellationError())
    }

    private func sendFailed(id: Int, error: any Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        sendTasks.removeValue(forKey: id)
        failPending(id: id, error: error)
    }

    private func failPending(id: Int, error: any Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        cancelledCommandIDs.remove(id)
        sendTasks[id]?.cancel()
        sendTasks.removeValue(forKey: id)
        guard let continuation = pending.removeValue(forKey: id) else {
            activeCommandIDs.remove(id)
            return
        }
        activeCommandIDs.remove(id)
        continuation.resume(throwing: error)
    }

    private func failAllPending(with error: any Error) {
        let waiters = pending
        pending.removeAll()
        activeCommandIDs.removeAll()
        for task in sendTasks.values { task.cancel() }
        sendTasks.removeAll()
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        cancelledCommandIDs.removeAll()
        for waiter in waiters.values {
            waiter.resume(throwing: error)
        }
    }

    private func receive(_ result: Result<Data, CDPError>) {
        switch result {
        case .success(let data):
            do {
                try handleMessage(data)
            } catch {
                transportDidEnd(error: error)
            }
        case .failure(let error):
            transportDidEnd(error: error)
        }
    }

    private func transportDidEnd(error: (any Error)?) {
        guard !isClosed else { return }
        receiverTask?.cancel()
        receiverTask = nil
        isClosed = true
        activeTargetSessionID = nil
        eventQueue.removeAll()
        eventResyncQueued = false
        eventWaiter?.resume(returning: nil)
        eventWaiter = nil
        let disconnectError = CDPError.disconnected(
            error?.localizedDescription ?? ChromiumBrowserDiagnostic.connectionClosed.message
        )
        failAllPending(with: disconnectError)
        for continuation in frameContinuations.values {
            continuation.finish()
        }
        frameContinuations.removeAll()
    }

    private func handleMessage(_ data: Data) throws {
        // Screencast frames carry hundreds of kilobytes of base64 per message
        // at up to display refresh rate. Decoding them through the recursive
        // `CDPValue` Codable path is the difference between a fluid pane and a
        // slideshow, so they take a dedicated `JSONSerialization` fast path.
        // Chromium also withholds the next frame until the previous one is
        // acknowledged, so the ack is issued here — before base64 decode and
        // before any consumer runs — to keep capture and delivery pipelined.
        if data.range(of: Self.screencastFrameToken) != nil, handleScreencastFrame(data) {
            return
        }
        let value = try JSONDecoder().decode(CDPValue.self, from: data)
        guard case .object(let object) = value else { throw CDPError.malformedMessage }
        if let rawID = object["id"]?.doubleValue, let id = Int(exactly: rawID) {
            timeoutTasks.removeValue(forKey: id)?.cancel()
            sendTasks[id]?.cancel()
            sendTasks.removeValue(forKey: id)
            activeCommandIDs.remove(id)
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = object["error"] {
                continuation.resume(throwing: CDPError.commandFailed(Self.errorMessage(error)))
            } else {
                continuation.resume(returning: object["result"] ?? .null)
            }
            return
        }
        guard let method = object["method"]?.stringValue else { return }
        if let activeTargetSessionID {
            let eventSessionID = object["sessionId"]?.stringValue
            let detachedSessionID: String?
            if method == "Target.detachedFromTarget",
               case .object(let parameters)? = object["params"] {
                detachedSessionID = parameters["sessionId"]?.stringValue
            } else {
                detachedSessionID = nil
            }
            guard eventSessionID == activeTargetSessionID ||
                    detachedSessionID == activeTargetSessionID else {
                return
            }
        }
        let event = CDPEvent(method: method, params: object["params"])
        enqueueEvent(event)
    }

    private static func pageTargetID(_ value: CDPValue) -> String? {
        guard case .object(let object) = value,
              object["type"]?.stringValue == "page",
              let targetID = object["targetId"]?.stringValue,
              !targetID.isEmpty else {
            return nil
        }
        return targetID
    }

    private static func errorMessage(_ value: CDPValue) -> String {
        guard case .object(let object) = value else {
            return ChromiumBrowserDiagnostic.unknownCDPError.message
        }
        return object["message"]?.stringValue ?? ChromiumBrowserDiagnostic.unknownCDPError.message
    }
}
