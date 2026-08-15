@preconcurrency import Foundation

/// CDP transport backed by one loopback WebSocket.
actor ChromiumCDPWebSocketTransport: ChromiumCDPTransport {
    private let endpoint: URL
    private let session: URLSession
    private let messageStream: AsyncStream<Result<Data, CDPError>>
    private let messageContinuation: AsyncStream<Result<Data, CDPError>>.Continuation
    private var socket: URLSessionWebSocketTask?
    private var receiverTask: Task<Void, Never>?
    private var isClosed = false

    init(endpoint: URL, session: URLSession) throws {
        guard endpoint.scheme?.lowercased() == "ws" || endpoint.scheme?.lowercased() == "wss" else {
            throw CDPError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.session = session
        let pair = AsyncStream<Result<Data, CDPError>>.makeStream()
        self.messageStream = pair.stream
        self.messageContinuation = pair.continuation
    }

    deinit {
        receiverTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        messageContinuation.finish()
    }

    func connect() {
        guard socket == nil else { return }
        isClosed = false
        let task = session.webSocketTask(with: endpoint)
        task.resume()
        socket = task
        receiverTask = Task { [weak self, task] in
            await self?.receiveLoop(socket: task)
        }
    }

    nonisolated func messages() -> AsyncStream<Result<Data, CDPError>> {
        messageStream
    }

    func send(_ data: Data) async throws {
        guard !isClosed, let socket else { throw CDPError.notConnected }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CDPError.protocolError(ChromiumBrowserDiagnostic.commandEncodingFailed.message)
        }
        do {
            try await socket.send(.string(text))
        } catch {
            throw CDPError.disconnected(error.localizedDescription)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        receiverTask?.cancel()
        receiverTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        messageContinuation.finish()
    }

    private func receiveLoop(socket expectedSocket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await expectedSocket.receive()
                switch message {
                case .string(let text):
                    messageContinuation.yield(.success(Data(text.utf8)))
                case .data(let data):
                    messageContinuation.yield(.success(data))
                @unknown default:
                    throw CDPError.malformedMessage
                }
            }
            receiveLoopDidEnd(socket: expectedSocket, error: nil)
        } catch {
            guard !Task.isCancelled else {
                receiveLoopDidEnd(socket: expectedSocket, error: nil)
                return
            }
            receiveLoopDidEnd(socket: expectedSocket, error: error)
        }
    }

    private func receiveLoopDidEnd(
        socket expectedSocket: URLSessionWebSocketTask,
        error: (any Error)?
    ) {
        guard socket === expectedSocket else { return }
        socket = nil
        receiverTask = nil
        isClosed = true
        if let error {
            messageContinuation.yield(.failure(.disconnected(error.localizedDescription)))
        }
        messageContinuation.finish()
    }
}
