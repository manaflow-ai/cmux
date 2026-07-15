import Foundation

/// Owns one browser-level Chrome DevTools Protocol WebSocket connection.
actor CDPConnection {
    private let webSocketTask: URLSessionWebSocketTask
    private let urlSession: URLSession
    private let eventContinuation: AsyncStream<CDPEvent>.Continuation
    private let eventStream: AsyncStream<CDPEvent>
    private var receiveTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<CDPJSONValue, any Error>] = [:]
    private var isClosed = false

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        self.urlSession = session
        self.webSocketTask = session.webSocketTask(with: url)
        (eventStream, eventContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
    }

    func connect() {
        guard receiveTask == nil else { return }
        webSocketTask.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveMessages()
        }
    }

    func events() -> AsyncStream<CDPEvent> { eventStream }

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
        let data = try JSONEncoder().encode(message)
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
            Task { [weak self, webSocketTask] in
                do {
                    try await webSocketTask.send(.data(data))
                } catch {
                    await self?.failPendingRequest(requestID, error: error)
                }
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask.cancel(with: .goingAway, reason: nil)
        urlSession.invalidateAndCancel()
        let error = BrowserEngineSessionError.chromiumProtocol("DevTools connection closed.")
        pendingRequests.values.forEach { $0.resume(throwing: error) }
        pendingRequests.removeAll()
        eventContinuation.finish()
    }

    private func failPendingRequest(_ requestID: Int, error: any Error) {
        pendingRequests.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    private func receiveMessages() async {
        do {
            while !Task.isCancelled {
                let message = try await webSocketTask.receive()
                let data: Data
                switch message {
                case .data(let value):
                    data = value
                case .string(let value):
                    data = Data(value.utf8)
                @unknown default:
                    continue
                }
                try handleMessage(data)
            }
        } catch {
            guard !isClosed else { return }
            isClosed = true
            pendingRequests.values.forEach { $0.resume(throwing: error) }
            pendingRequests.removeAll()
            eventContinuation.finish()
        }
    }

    private func handleMessage(_ data: Data) throws {
        let payload = try JSONDecoder().decode([String: CDPJSONValue].self, from: data)
        if let requestID = payload["id"]?.intValue,
           let continuation = pendingRequests.removeValue(forKey: requestID) {
            if let remoteError = payload["error"]?.objectValue {
                let message = remoteError["message"]?.stringValue ?? "Unknown DevTools error"
                continuation.resume(throwing: BrowserEngineSessionError.chromiumProtocol(message))
            } else {
                continuation.resume(returning: payload["result"] ?? .null)
            }
            return
        }
        guard let method = payload["method"]?.stringValue else { return }
        eventContinuation.yield(CDPEvent(
            method: method,
            parameters: payload["params"]?.objectValue ?? [:],
            sessionID: payload["sessionId"]?.stringValue
        ))
    }
}
