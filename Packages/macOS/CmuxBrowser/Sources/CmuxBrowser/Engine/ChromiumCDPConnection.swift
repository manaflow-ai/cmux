@preconcurrency import Foundation

/// Actor-isolated CDP command router over an injected message transport.
actor ChromiumCDPConnection {
    typealias EventContinuation = AsyncStream<CDPEvent>.Continuation

    private let transport: any ChromiumCDPTransport
    private var receiverTask: Task<Void, Never>?
    private var nextCommandID = 1
    private var pending: [Int: CheckedContinuation<CDPValue, any Error>] = [:]
    private var activeCommandIDs: Set<Int> = []
    private var cancelledCommandIDs: Set<Int> = []
    private var sendTasks: [Int: Task<Void, Never>] = [:]
    private var eventContinuations: [UUID: EventContinuation] = [:]
    private var activeTargetSessionID: String?
    private var isClosed = false

    init(endpoint: URL, session: URLSession) throws {
        transport = try ChromiumCDPWebSocketTransport(endpoint: endpoint, session: session)
    }

    init(transport: any ChromiumCDPTransport) {
        self.transport = transport
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

    func events() -> AsyncStream<CDPEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            guard !isClosed else {
                continuation.finish()
                return
            }
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
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
            for task in sendTasks.values { task.cancel() }
            sendTasks.removeAll()
            let waiters = pending
            pending.removeAll()
            activeCommandIDs.removeAll()
            cancelledCommandIDs.removeAll()
            for waiter in waiters.values {
                waiter.resume(
                    throwing: CDPError.disconnected(ChromiumBrowserDiagnostic.connectionClosed.message)
                )
            }
            for continuation in eventContinuations.values {
                continuation.finish()
            }
            eventContinuations.removeAll()
        }
        // A peer-ended message stream marks the connection closed before the
        // owner calls shutdown. Always forward the idempotent close so the
        // underlying socket or pipe releases its descriptors in that path.
        await transport.close()
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func cancelPending(id: Int) {
        guard activeCommandIDs.contains(id) else { return }
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
        sendTasks.removeValue(forKey: id)
        failPending(id: id, error: error)
    }

    private func failPending(id: Int, error: any Error) {
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
        let disconnectError = CDPError.disconnected(
            error?.localizedDescription ?? ChromiumBrowserDiagnostic.connectionClosed.message
        )
        failAllPending(with: disconnectError)
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    private func handleMessage(_ data: Data) throws {
        let value = try JSONDecoder().decode(CDPValue.self, from: data)
        guard case .object(let object) = value else { throw CDPError.malformedMessage }
        if let rawID = object["id"]?.doubleValue, let id = Int(exactly: rawID) {
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
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
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
