import Foundation

/// Sendable transport boundary for the browser-level DevTools WebSocket.
protocol CDPWebSocketTransport: Sendable {
    func resume()
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func cancel()
}

private final class URLSessionCDPWebSocketTransport: CDPWebSocketTransport, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        self.session = session
        self.task = session.webSocketTask(with: url)
    }

    func resume() {
        task.resume()
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data):
            return data
        case .string(let value):
            return Data(value.utf8)
        @unknown default:
            return Data()
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Owns one browser-level Chrome DevTools Protocol WebSocket connection.
actor CDPConnection {
    private struct PendingRequest {
        let continuation: CheckedContinuation<CDPJSONValue, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct EventSubscriber {
        let sessionID: String
        let continuation: AsyncStream<CDPEvent>.Continuation
    }

    private let transport: any CDPWebSocketTransport
    private let requestTimeout: Duration
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var receiveTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var eventSubscribers: [UUID: EventSubscriber] = [:]
    private var isClosed = false

    init(url: URL, requestTimeout: Duration = .seconds(10)) {
        self.transport = URLSessionCDPWebSocketTransport(url: url)
        self.requestTimeout = requestTimeout
    }

    init(
        transport: any CDPWebSocketTransport,
        requestTimeout: Duration = .seconds(10)
    ) {
        self.transport = transport
        self.requestTimeout = requestTimeout
    }

    func connect() {
        guard receiveTask == nil else { return }
        transport.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveMessages()
        }
    }

    func events(sessionID: String) -> AsyncStream<CDPEvent> {
        let subscriberID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: CDPEvent.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        guard !isClosed else {
            continuation.finish()
            return stream
        }
        eventSubscribers[subscriberID] = EventSubscriber(
            sessionID: sessionID,
            continuation: continuation
        )
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeEventSubscriber(subscriberID)
            }
        }
        return stream
    }

    func isOpen() -> Bool { !isClosed }

    func send(
        method: String,
        parameters: [String: CDPJSONValue] = [:],
        sessionID: String? = nil
    ) async throws -> CDPJSONValue {
        guard !isClosed else { throw BrowserEngineSessionError.chromiumProtocol("DevTools connection is closed.") }
        let requestID = nextRequestID
        nextRequestID += 1
        var message: [String: CDPJSONValue] = [
            "id": .number(Double(requestID)),
            "method": .string(method),
            "params": .object(parameters),
        ]
        if let sessionID { message["sessionId"] = .string(sessionID) }
        let data = try encoder.encode(message)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeoutTask = Task { [weak self, requestTimeout] in
                    do {
                        // A bounded request deadline is intentional; a missing CDP reply
                        // must not retain its continuation forever.
                        try await ContinuousClock().sleep(for: requestTimeout)
                    } catch {
                        return
                    }
                    await self?.failPendingRequest(
                        requestID,
                        error: BrowserEngineSessionError.chromiumProtocol(
                            "DevTools request \(method) timed out."
                        )
                    )
                }
                pendingRequests[requestID] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { [weak self, transport] in
                    do {
                        try await transport.send(data)
                    } catch {
                        await self?.failPendingRequest(requestID, error: error)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task {
                await self?.failPendingRequest(requestID, error: CancellationError())
            }
        }
    }

    /// Sends an ordered command without retaining a request continuation.
    ///
    /// Input commands use this path because their replies carry no state and waiting
    /// for each reply would serialize typing behind a full protocol round trip.
    func sendUnacknowledged(
        method: String,
        parameters: [String: CDPJSONValue] = [:],
        sessionID: String? = nil
    ) async throws {
        guard !isClosed else {
            throw BrowserEngineSessionError.chromiumProtocol("DevTools connection is closed.")
        }
        let requestID = nextRequestID
        nextRequestID += 1
        var message: [String: CDPJSONValue] = [
            "id": .number(Double(requestID)),
            "method": .string(method),
            "params": .object(parameters),
        ]
        if let sessionID {
            message["sessionId"] = .string(sessionID)
        }
        try await transport.send(encoder.encode(message))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        receiveTask?.cancel()
        receiveTask = nil
        transport.cancel()
        let error = BrowserEngineSessionError.chromiumProtocol("DevTools connection closed.")
        failAllPendingRequests(error: error)
        finishEventSubscribers()
    }

    private func failPendingRequest(_ requestID: Int, error: any Error) {
        guard let request = pendingRequests.removeValue(forKey: requestID) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    private func failAllPendingRequests(error: any Error) {
        let requests = Array(pendingRequests.values)
        pendingRequests.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func receiveMessages() async {
        do {
            while !Task.isCancelled {
                let data = try await transport.receive()
                guard !data.isEmpty else { continue }
                try handleMessage(data)
            }
        } catch {
            guard !isClosed else { return }
            isClosed = true
            transport.cancel()
            receiveTask = nil
            failAllPendingRequests(error: error)
            finishEventSubscribers()
        }
    }

    private func handleMessage(_ data: Data) throws {
        let payload = try decoder.decode([String: CDPJSONValue].self, from: data)
        if let requestID = payload["id"]?.intValue,
           let request = pendingRequests.removeValue(forKey: requestID) {
            request.timeoutTask.cancel()
            if let remoteError = payload["error"]?.objectValue {
                let message = remoteError["message"]?.stringValue ?? "Unknown DevTools error"
                request.continuation.resume(throwing: BrowserEngineSessionError.chromiumProtocol(message))
            } else {
                request.continuation.resume(returning: payload["result"] ?? .null)
            }
            return
        }
        guard let method = payload["method"]?.stringValue else { return }
        let event = CDPEvent(
            method: method,
            parameters: payload["params"]?.objectValue ?? [:],
            sessionID: payload["sessionId"]?.stringValue
        )
        for subscriber in eventSubscribers.values where
            event.sessionID == nil || event.sessionID == subscriber.sessionID {
            subscriber.continuation.yield(event)
        }
    }

    private func removeEventSubscriber(_ subscriberID: UUID) {
        eventSubscribers.removeValue(forKey: subscriberID)
    }

    private func finishEventSubscribers() {
        let subscribers = Array(eventSubscribers.values)
        eventSubscribers.removeAll()
        for subscriber in subscribers {
            subscriber.continuation.finish()
        }
    }
}
