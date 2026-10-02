public import Foundation
@preconcurrency import Network

/// Errors raised by the short-lived TCP signaling bootstrap.
public enum CmxWebRTCSignalingError: Error, Equatable, Sendable {
    /// The signaling endpoint is malformed.
    case invalidEndpoint
    /// The connection did not reach ready before its deadline.
    case timedOut
    /// The peer closed the signaling stream.
    case closed
    /// A second receive was started before the first completed.
    case receiveAlreadyInProgress
    /// The signaling payload was too large.
    case messageTooLarge
    /// The signaling payload could not be encoded or decoded.
    case invalidMessage
    /// Network.framework reported a failure.
    case connectionFailed(String)
}

/// A newline-delimited JSON signaling connection backed by Network.framework
/// or an authenticated public WebSocket relay.
public actor CmxWebRTCSignalingConnection {
    private static let maximumMessageLength = 256 * 1024

    private let connection: NWConnection?
    private let webSocket: URLSessionWebSocketTask?
    private let callbackQueue: DispatchQueue
    private var started = false
    private var ready = false
    private var closed = false
    private var receiveBuffer = Data()
    private var receiveInProgress = false
    private var receiveContinuation: CheckedContinuation<CmxWebRTCSignalMessage?, any Error>?
    private var connectContinuation: CheckedContinuation<Void, any Error>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var sendContinuations: [UUID: CheckedContinuation<Void, any Error>] = [:]

    /// Creates a signaling connection around an accepted or not-yet-started socket.
    ///
    /// - Parameter connection: The Network.framework TCP connection.
    init(connection: NWConnection) {
        self.connection = connection
        webSocket = nil
        callbackQueue = DispatchQueue(
            label: "dev.cmux.mobile.webrtc-signaling.\(UUID().uuidString)"
        )
    }

    private init(webSocket: URLSessionWebSocketTask) {
        connection = nil
        self.webSocket = webSocket
        callbackQueue = DispatchQueue(
            label: "dev.cmux.mobile.webrtc-signaling.\(UUID().uuidString)"
        )
    }

    /// Opens a signaling connection to a route endpoint.
    ///
    /// - Parameters:
    ///   - host: The host name or numeric address.
    ///   - port: The TCP signaling port.
    ///   - timeoutNanoseconds: Connection deadline.
    /// - Returns: A ready signaling connection.
    /// - Throws: ``CmxWebRTCSignalingError`` when the endpoint cannot be opened.
    public static func connect(
        host: String,
        port: Int,
        timeoutNanoseconds: UInt64
    ) async throws -> CmxWebRTCSignalingConnection {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0),
              nwPort != .any else {
            throw CmxWebRTCSignalingError.invalidEndpoint
        }
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(
            host: NWEndpoint.Host(normalizedHost),
            port: nwPort,
            using: parameters
        )
        let signaling = CmxWebRTCSignalingConnection(connection: connection)
        try await signaling.start(timeoutNanoseconds: timeoutNanoseconds)
        return signaling
    }

    /// Opens an authenticated public relay connection. The route token is a
    /// short-lived capability minted by the Mac's listener and the Stack token
    /// authenticates the account at the Worker before the Durable Object pairs
    /// the two peers.
    public static func connectWebSocket(
        url: URL,
        role: String,
        routeToken: String,
        tokens: (accessToken: String, refreshToken: String?)
    ) async throws -> CmxWebRTCSignalingConnection {
        guard !routeToken.isEmpty,
              !tokens.accessToken.isEmpty,
              role == "host" || role == "client",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" || scheme == "http" || scheme == "https",
              components.host != nil else {
            throw CmxWebRTCSignalingError.invalidEndpoint
        }
        if scheme == "http" { components.scheme = "ws" }
        if scheme == "https" { components.scheme = "wss" }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "role", value: role))
        queryItems.append(URLQueryItem(name: "session", value: routeToken))
        queryItems.append(URLQueryItem(name: "route_token", value: routeToken))
        components.queryItems = queryItems
        guard let relayURL = components.url else {
            throw CmxWebRTCSignalingError.invalidEndpoint
        }
        var request = URLRequest(url: relayURL)
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let refreshToken = tokens.refreshToken, !refreshToken.isEmpty {
            request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        }
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageLength
        task.resume()
        let signaling = CmxWebRTCSignalingConnection(webSocket: task)
        try await signaling.start(timeoutNanoseconds: 15 * 1_000_000_000)
        return signaling
    }

    /// Starts the socket and waits until Network.framework reports ready.
    ///
    /// - Parameter timeoutNanoseconds: Connection deadline.
    /// - Throws: ``CmxWebRTCSignalingError`` when readiness fails.
    public func start(timeoutNanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        if ready { return }
        guard !started else { throw CmxWebRTCSignalingError.connectionFailed("already started") }
        started = true
        guard let connection else {
            ready = true
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(state: state) }
        }
        connection.start(queue: callbackQueue)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connectContinuation = continuation
                connectTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: max(1, timeoutNanoseconds))
                    } catch {
                        return
                    }
                    await self?.timeoutStart()
                }
            }
        } onCancel: {
            Task { await self.cancelStart() }
        }
    }

    /// Sends one signaling message.
    ///
    /// - Parameter message: The message to encode and send.
    /// - Throws: ``CmxWebRTCSignalingError`` when the socket is closed.
    public func send(_ message: CmxWebRTCSignalMessage) async throws {
        guard ready, !closed else { throw CmxWebRTCSignalingError.closed }
        guard var encoded = try? JSONEncoder().encode(message) else {
            throw CmxWebRTCSignalingError.invalidMessage
        }
        encoded.append(0x0A)
        guard encoded.count <= Self.maximumMessageLength else {
            throw CmxWebRTCSignalingError.messageTooLarge
        }
        if let webSocket {
            guard let text = String(data: encoded, encoding: .utf8) else {
                throw CmxWebRTCSignalingError.invalidMessage
            }
            do {
                try await webSocket.send(.string(text))
            } catch {
                throw CmxWebRTCSignalingError.connectionFailed(String(describing: error))
            }
            return
        }
        let operationID = UUID()
        guard let connection else { throw CmxWebRTCSignalingError.closed }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sendContinuations[operationID] = continuation
                connection.send(
                    content: encoded,
                    contentContext: .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] error in
                        Task {
                            await self?.finishSend(operationID: operationID, error: error)
                        }
                    }
                )
            }
        } onCancel: {
            Task { await self.cancelSend(operationID: operationID) }
        }
    }

    /// Receives the next signaling message, or nil after a clean close.
    ///
    /// - Returns: The decoded message, or nil when the peer ended the stream.
    /// - Throws: ``CmxWebRTCSignalingError`` for malformed or failed input.
    public func receive() async throws -> CmxWebRTCSignalMessage? {
        guard ready, !closed else { throw CmxWebRTCSignalingError.closed }
        guard !receiveInProgress else {
            throw CmxWebRTCSignalingError.receiveAlreadyInProgress
        }
        if let message = try takeMessageFromBuffer() {
            return message
        }
        receiveInProgress = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiveContinuation = continuation
                receiveNextChunk()
            }
        } onCancel: {
            Task { await self.cancelReceive() }
        }
    }

    /// Closes the signaling socket and settles any pending operation.
    public func close() {
        guard !closed else { return }
        closed = true
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        connection?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        connectContinuation?.resume(throwing: CmxWebRTCSignalingError.closed)
        connectContinuation = nil
        receiveContinuation?.resume(returning: nil)
        receiveContinuation = nil
        receiveInProgress = false
        for continuation in sendContinuations.values {
            continuation.resume(throwing: CmxWebRTCSignalingError.closed)
        }
        sendContinuations.removeAll()
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            connectContinuation?.resume()
            connectContinuation = nil
        case let .failed(error):
            finishConnectionFailure(error: error)
        case .cancelled:
            finishConnectionFailure(error: nil)
        case .setup, .preparing, .waiting:
            break
        @unknown default:
            finishConnectionFailure(error: nil)
        }
    }

    private func finishConnectionFailure(error: NWError?) {
        guard !closed else { return }
        closed = true
        let failure: CmxWebRTCSignalingError = if let error {
            .connectionFailed(String(describing: error))
        } else {
            .closed
        }
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        connectContinuation?.resume(throwing: failure)
        connectContinuation = nil
        receiveContinuation?.resume(throwing: failure)
        receiveContinuation = nil
        receiveInProgress = false
        for continuation in sendContinuations.values {
            continuation.resume(throwing: failure)
        }
        sendContinuations.removeAll()
    }

    private func timeoutStart() {
        guard !ready, !closed else { return }
        connection?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        connectContinuation?.resume(throwing: CmxWebRTCSignalingError.timedOut)
        connectContinuation = nil
        closed = true
    }

    private func cancelStart() {
        guard !ready, !closed else { return }
        connection?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        connectContinuation?.resume(throwing: CancellationError())
        connectContinuation = nil
        closed = true
    }

    private func receiveNextChunk() {
        if webSocket != nil {
            receiveNextWebSocketMessage()
            return
        }
        guard !closed else {
            receiveContinuation?.resume(throwing: CmxWebRTCSignalingError.closed)
            receiveContinuation = nil
            receiveInProgress = false
            return
        }
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumMessageLength
        ) { [weak self] data, _, isComplete, error in
            Task {
                await self?.handleReceived(
                    data: data,
                    isComplete: isComplete,
                    error: error
                )
            }
        }
    }

    private func receiveNextWebSocketMessage() {
        guard let webSocket else {
            receiveContinuation?.resume(throwing: CmxWebRTCSignalingError.closed)
            receiveContinuation = nil
            receiveInProgress = false
            return
        }
        Task { [weak self] in
            do {
                let message = try await webSocket.receive()
                await self?.handleWebSocketMessage(message)
            } catch {
                await self?.handleWebSocketError(error)
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .string(text):
            handleReceived(data: Data(text.utf8), isComplete: false, error: nil)
        case let .data(data):
            handleReceived(data: data, isComplete: false, error: nil)
        @unknown default:
            handleWebSocketError(CmxWebRTCSignalingError.invalidMessage)
        }
    }

    private func handleWebSocketError(_ error: any Error) {
        guard !closed else { return }
        receiveContinuation?.resume(
            throwing: CmxWebRTCSignalingError.connectionFailed(String(describing: error))
        )
        receiveContinuation = nil
        receiveInProgress = false
        closed = true
    }

    private func handleReceived(data: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            receiveContinuation?.resume(throwing: CmxWebRTCSignalingError.connectionFailed(String(describing: error)))
            receiveContinuation = nil
            receiveInProgress = false
            return
        }
        if let data, !data.isEmpty {
            receiveBuffer.append(data)
            guard receiveBuffer.count <= Self.maximumMessageLength else {
                receiveContinuation?.resume(throwing: CmxWebRTCSignalingError.messageTooLarge)
                receiveContinuation = nil
                receiveInProgress = false
                close()
                return
            }
            if let message = try? takeMessageFromBuffer() {
                receiveContinuation?.resume(returning: message)
                receiveContinuation = nil
                receiveInProgress = false
                return
            }
        }
        if isComplete {
            receiveContinuation?.resume(returning: nil)
            receiveContinuation = nil
            receiveInProgress = false
            return
        }
        receiveNextChunk()
    }

    private func takeMessageFromBuffer() throws -> CmxWebRTCSignalMessage? {
        guard let newline = receiveBuffer.firstIndex(of: 0x0A) else { return nil }
        let line = receiveBuffer[..<newline]
        receiveBuffer.removeSubrange(...newline)
        guard !line.isEmpty else { throw CmxWebRTCSignalingError.invalidMessage }
        guard let message = try? JSONDecoder().decode(CmxWebRTCSignalMessage.self, from: line) else {
            throw CmxWebRTCSignalingError.invalidMessage
        }
        return message
    }

    private func cancelReceive() {
        guard receiveInProgress else { return }
        receiveContinuation?.resume(throwing: CancellationError())
        receiveContinuation = nil
        receiveInProgress = false
    }

    private func finishSend(operationID: UUID, error: NWError?) {
        guard let continuation = sendContinuations.removeValue(forKey: operationID) else { return }
        if let error {
            continuation.resume(throwing: CmxWebRTCSignalingError.connectionFailed(String(describing: error)))
        } else {
            continuation.resume()
        }
    }

    private func cancelSend(operationID: UUID) {
        guard let continuation = sendContinuations.removeValue(forKey: operationID) else { return }
        continuation.resume(throwing: CancellationError())
    }
}
