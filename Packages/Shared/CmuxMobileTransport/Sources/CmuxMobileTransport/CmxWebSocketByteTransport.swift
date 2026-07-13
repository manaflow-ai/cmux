public import CMUXMobileCore
public import Foundation

/// A ``CmxByteTransport`` over a single `URLSessionWebSocketTask`.
///
/// The actor owns the task and operation state so connect/receive/send/close
/// are serialized without locks.
public actor CmxWebSocketByteTransport: CmxByteTransport {
    private enum TransportState {
        case idle
        case connecting
        case ready
        case failed(CmxWebSocketByteTransportError)
        case closed
    }

    private let url: URL
    private let endpoint: CmxAttachEndpoint
    private var task: URLSessionWebSocketTask?
    private var state: TransportState = .idle
    private var receiveInProgress = false
    private var sendInProgress = false

    /// Creates a WebSocket transport for a URL string.
    /// - Parameter urlString: The `ws` or `wss` URL to connect to.
    /// - Throws: ``CmxWebSocketByteTransportError`` when the URL is invalid or uses an unsupported scheme.
    public init(urlString: String) throws {
        let normalizedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: normalizedURL),
            url.scheme != nil
        else {
            throw CmxWebSocketByteTransportError.invalidURL(urlString)
        }
        guard Self.supportedSchemes.contains(url.scheme?.lowercased() ?? "") else {
            throw CmxWebSocketByteTransportError.unsupportedURLScheme(url.scheme)
        }
        self.url = url
        endpoint = .url(normalizedURL)
    }

    /// Creates a WebSocket transport from a WebSocket URL attach route.
    /// - Parameter route: The route to connect to; must be `.websocket` with a `.url` endpoint.
    /// - Throws: ``CmxWebSocketByteTransportError`` when the route kind, endpoint, or URL is invalid.
    public init(route: CmxAttachRoute) throws {
        try route.validate()
        guard route.kind == .websocket else {
            throw CmxWebSocketByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard case let .url(urlString) = route.endpoint else {
            throw CmxWebSocketByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        try self.init(urlString: urlString)
    }

    /// Opens the WebSocket and waits until the server answers a protocol ping.
    /// - Throws: ``CmxWebSocketByteTransportError`` or `CancellationError`.
    public func connect() async throws {
        try Task.checkCancellation()
        switch state {
        case .idle:
            break
        case .connecting:
            throw CmxWebSocketByteTransportError.connectAlreadyInProgress
        case .ready:
            return
        case let .failed(error):
            throw error
        case .closed:
            throw CmxWebSocketByteTransportError.alreadyClosed
        }

        let webSocketTask = URLSession.shared.webSocketTask(with: url)
        task = webSocketTask
        state = .connecting
        webSocketTask.resume()

        do {
            try await withTaskCancellationHandler {
                try await Self.awaitPong(from: webSocketTask)
            } onCancel: {
                Task { await self.close() }
            }
            guard case .connecting = state else {
                if case .closed = state {
                    throw CmxWebSocketByteTransportError.alreadyClosed
                }
                return
            }
            state = .ready
        } catch is CancellationError {
            closeAfterFailure(CmxWebSocketByteTransportError.alreadyClosed)
            throw CancellationError()
        } catch {
            let transportError = CmxWebSocketByteTransportError.connectionFailed(
                String(describing: error)
            )
            closeAfterFailure(transportError)
            throw transportError
        }
    }

    /// Receives the next binary WebSocket message, or `nil` at end of stream.
    /// - Returns: The next received `Data`, or `nil` once the peer or local caller closed.
    /// - Throws: ``CmxWebSocketByteTransportError`` or `CancellationError`.
    public func receive() async throws -> Data? {
        try Task.checkCancellation()
        let webSocketTask = try readyTask()
        guard !receiveInProgress else {
            throw CmxWebSocketByteTransportError.receiveAlreadyInProgress
        }

        receiveInProgress = true
        defer { receiveInProgress = false }

        do {
            let message = try await webSocketTask.receive()
            switch message {
            case let .data(data):
                return data
            case .string:
                throw CmxWebSocketByteTransportError.receivedTextMessage
            @unknown default:
                throw CmxWebSocketByteTransportError.receiveFailed("Unknown WebSocket message.")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isClosed {
                return nil
            }
            let transportError = CmxWebSocketByteTransportError.receiveFailed(
                String(describing: error)
            )
            failTransport(transportError)
            throw transportError
        }
    }

    /// Sends bytes as a binary WebSocket message. Empty data is a no-op.
    /// - Parameter data: The bytes to write.
    /// - Throws: ``CmxWebSocketByteTransportError`` or `CancellationError`.
    public func send(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        try Task.checkCancellation()
        let webSocketTask = try readyTask()
        guard !sendInProgress else {
            throw CmxWebSocketByteTransportError.sendAlreadyInProgress
        }

        sendInProgress = true
        defer { sendInProgress = false }

        do {
            try await webSocketTask.send(.data(data))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isClosed {
                throw CmxWebSocketByteTransportError.alreadyClosed
            }
            let transportError = CmxWebSocketByteTransportError.sendFailed(
                String(describing: error)
            )
            failTransport(transportError)
            throw transportError
        }
    }

    /// Cancels the WebSocket task.
    public func close() async {
        closeTask()
    }

    /// Returns diagnostics identifying the WebSocket route.
    public func connectionDiagnostics() async -> CmxConnectionDiagnostics {
        CmxConnectionDiagnostics(kind: .websocket, endpoint: endpoint, rttMilliseconds: nil)
    }

    private static let supportedSchemes: Set<String> = ["ws", "wss"]

    private static func awaitPong(from task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func readyTask() throws -> URLSessionWebSocketTask {
        switch state {
        case .ready:
            guard let task else {
                throw CmxWebSocketByteTransportError.notConnected
            }
            return task
        case let .failed(error):
            throw error
        case .closed:
            throw CmxWebSocketByteTransportError.alreadyClosed
        case .idle, .connecting:
            throw CmxWebSocketByteTransportError.notConnected
        }
    }

    private func failTransport(_ error: CmxWebSocketByteTransportError) {
        guard !isTerminal else {
            return
        }
        state = .failed(error)
        closeTaskWithoutStateChange()
    }

    private func closeAfterFailure(_ error: CmxWebSocketByteTransportError) {
        state = .failed(error)
        closeTaskWithoutStateChange()
    }

    private func closeTask() {
        guard !isClosed else {
            return
        }
        state = .closed
        closeTaskWithoutStateChange()
    }

    private func closeTaskWithoutStateChange() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private var isTerminal: Bool {
        switch state {
        case .failed, .closed:
            return true
        case .idle, .connecting, .ready:
            return false
        }
    }

    private var isClosed: Bool {
        if case .closed = state {
            return true
        }
        return false
    }
}
