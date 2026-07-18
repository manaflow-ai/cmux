public import Foundation

/// Actor-owned host WebSocket with typed JSON frames and sequence ordering.
public actor WorkspaceShareClient {
    private struct PendingSend {
        let id: UInt64
        let socket: URLSessionWebSocketTask
        let message: URLSessionWebSocketTask.Message
        let byteCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var continuation: AsyncStream<WorkspaceShareEvent>.Continuation?
    private var clientSequence: UInt64 = 0
    private var lastServerSequence: UInt64?
    private var nextPendingSendID: UInt64 = 0
    private var pendingSends: [PendingSend] = []
    private var sendDrainTask: Task<Void, Never>?
    private var sendGeneration: UInt64 = 0
    private var pendingSendBudget = WorkspaceSharePendingSendBudget()

    /// Creates a host transport.
    /// - Parameter urlSession: URL session used to open the WebSocket.
    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Opens the room's owner socket.
    /// - Parameters:
    ///   - session: Room endpoint and host capability.
    ///   - accessToken: Current Stack access token.
    /// - Returns: Stream of validated frames and disconnect events.
    public func connect(
        session: WorkspaceShareSession,
        accessToken: String
    ) -> AsyncStream<WorkspaceShareEvent> {
        disconnect(reason: "replaced")
        var request = URLRequest(url: session.socketUrl)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(session.hostCapability, forHTTPHeaderField: "X-Cmux-Share-Capability")
        request.setValue("cmux-share.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let socket = urlSession.webSocketTask(with: request)
        task = socket
        clientSequence = 0
        lastServerSequence = nil
        let stream = AsyncStream<WorkspaceShareEvent> { continuation in
            self.continuation = continuation
        }
        socket.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket)
        }
        handshakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await self?.failHandshakeIfNeeded(socket)
        }
        return stream
    }

    /// Sends one protocol frame.
    /// - Parameters:
    ///   - type: Stable frame type.
    ///   - payload: JSON object payload.
    public func send(type: String, payload: WorkspaceShareJSONValue) async throws {
        guard let socket = task else { throw WorkspaceShareError.unavailable }
        clientSequence &+= 1
        let frame = WorkspaceShareWireFrame(type: type, seq: clientSequence, payload: payload)
        let data = try JSONEncoder().encode(frame)
        guard let string = String(data: data, encoding: .utf8) else {
            throw WorkspaceShareError.invalidResponse
        }
        guard pendingSendBudget.reserve(byteCount: data.count) else {
            disconnect(reason: "send_queue_overflow")
            throw WorkspaceShareError.transport("send_queue_overflow")
        }
        try await withCheckedThrowingContinuation { continuation in
            nextPendingSendID &+= 1
            pendingSends.append(PendingSend(
                id: nextPendingSendID,
                socket: socket,
                message: .string(string),
                byteCount: data.count,
                continuation: continuation
            ))
            startSendDrainIfNeeded()
        }
    }

    /// Closes the current socket and finishes its event stream.
    /// - Parameter reason: Short non-sensitive close reason.
    public func disconnect(reason: String = "host_closed") {
        sendGeneration &+= 1
        sendDrainTask?.cancel()
        sendDrainTask = nil
        failPendingSends(with: WorkspaceShareError.transport(reason))
        receiveTask?.cancel()
        receiveTask = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        task?.cancel(with: .normalClosure, reason: reason.data(using: .utf8))
        task = nil
        continuation?.finish()
        continuation = nil
    }

    private func startSendDrainIfNeeded() {
        guard sendDrainTask == nil, !pendingSends.isEmpty else { return }
        let generation = sendGeneration
        sendDrainTask = Task { [weak self] in
            await self?.drainPendingSends(generation: generation)
        }
    }

    private func drainPendingSends(generation: UInt64) async {
        while generation == sendGeneration,
              !Task.isCancelled,
              let pending = pendingSends.first {
            do {
                try await pending.socket.send(pending.message)
            } catch {
                guard generation == sendGeneration else { return }
                let transportError = WorkspaceShareError.transport(String(describing: error))
                failPendingSends(with: transportError)
                pending.socket.cancel(with: .goingAway, reason: Data("send_failed".utf8))
                sendDrainTask = nil
                return
            }
            guard generation == sendGeneration,
                  pendingSends.first?.id == pending.id else { return }
            pendingSendBudget.release(byteCount: pending.byteCount)
            pendingSends.removeFirst().continuation.resume()
        }
        guard generation == sendGeneration else { return }
        sendDrainTask = nil
        startSendDrainIfNeeded()
    }

    private func failPendingSends(with error: WorkspaceShareError) {
        let pending = pendingSends
        pendingSends.removeAll(keepingCapacity: true)
        pendingSendBudget.reset()
        for frame in pending {
            frame.continuation.resume(throwing: error)
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled, task === socket {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case let .data(value): data = value
                case let .string(value): data = Data(value.utf8)
                @unknown default: continue
                }
                guard data.count <= 2 * 1_024 * 1_024,
                      let frame = try? JSONDecoder().decode(WorkspaceShareWireFrame.self, from: data),
                      frame.v == 1,
                      frame.type.count <= 64,
                      lastServerSequence.map({ frame.seq > $0 }) ?? true else {
                    continue
                }
                lastServerSequence = frame.seq
                handshakeTask?.cancel()
                handshakeTask = nil
                continuation?.yield(.frame(frame))
            } catch {
                guard !Task.isCancelled, task === socket else { return }
                continuation?.yield(.disconnected(String(describing: error)))
                handshakeTask?.cancel()
                handshakeTask = nil
                continuation?.finish()
                continuation = nil
                task = nil
                return
            }
        }
    }

    private func failHandshakeIfNeeded(_ socket: URLSessionWebSocketTask) {
        guard task === socket, lastServerSequence == nil else { return }
        socket.cancel(with: .goingAway, reason: Data("handshake_timeout".utf8))
        continuation?.yield(.disconnected("handshake_timeout"))
        continuation?.finish()
        continuation = nil
        receiveTask?.cancel()
        receiveTask = nil
        handshakeTask = nil
        task = nil
    }
}
