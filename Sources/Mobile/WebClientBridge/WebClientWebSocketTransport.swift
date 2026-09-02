import CMUXMobileCore
import Foundation
@preconcurrency import Network

/// Adapts one Network.framework WebSocket message stream to the existing
/// length-prefixed mobile byte transport. The adapter performs the one-time
/// `cmux.web/1` hello before ``MobileHostConnection`` starts reading RPC
/// frames; after that point browser requests and server events remain the
/// ordinary `MobileHostRPCEnvelope` bytes used by iOS.
actor WebClientWebSocketTransport: CmxByteTransport {
    static let protocolIdentifier = "cmux.web/1"
    static let webSocketSubprotocol = "cmux.web.v1"
    static let protocolVersion = 1
    /// Every browser-to-Mac message, including the unauthenticated hello.
    static let maximumClientMessageByteCount = 4 * 1024
    /// Mac-to-browser snapshots/events may carry bounded terminal state.
    static let maximumServerMessageByteCount = 16 * 1024 * 1024
    private static let callbackQueueLabel = "dev.cmux.web-client.websocket"

    private enum State {
        case idle
        case connecting
        case ready
        case closed
        case failed
    }

    private let connection: NWConnection
    private let callbackQueue: DispatchQueue
    private let grantStore: WebClientGrantStore
    private let handshakeTimeoutSleep: @Sendable () async throws -> Void
    private let sendTimeoutSleep: @Sendable () async throws -> Void
    private var state: State = .idle
    private var stateError: Error?
    private var connectWaiters: [CheckedContinuation<Void, any Error>] = []
    private var receiveWaiter: CheckedContinuation<Data, any Error>?
    private var pendingSendWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var pendingSendTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var authenticatedGrant: UUID?
    private var sendBuffer = Data()

    nonisolated static func validatesProtocol(
        _ protocolValue: String?,
        version: Int?
    ) -> Bool {
        protocolValue == protocolIdentifier
            && (version == nil || version == protocolVersion)
    }

    /// Validates optional per-message protocol metadata after the hello has
    /// negotiated the connection. The existing mobile RPC/event envelopes do
    /// not carry these fields, so an absent pair is valid; an explicitly
    /// supplied pair must still match the negotiated bridge protocol.
    nonisolated static func validatesMessageProtocol(
        _ object: [String: Any]?
    ) -> Bool {
        guard let object else { return false }
        let hasProtocolMetadata = object["protocol"] != nil
            || object["protocol_version"] != nil
        return !hasProtocolMetadata || Self.validatesProtocol(
            object["protocol"] as? String,
            version: object["protocol_version"] as? Int
        )
    }

    init(
        connection: NWConnection,
        grantStore: WebClientGrantStore,
        handshakeTimeoutSleep: @escaping @Sendable () async throws -> Void = {
            try await ContinuousClock().sleep(for: .seconds(10))
        },
        sendTimeoutSleep: @escaping @Sendable () async throws -> Void = {
            try await ContinuousClock().sleep(for: .seconds(30))
        }
    ) {
        self.connection = connection
        self.grantStore = grantStore
        self.handshakeTimeoutSleep = handshakeTimeoutSleep
        self.sendTimeoutSleep = sendTimeoutSleep
        self.callbackQueue = DispatchQueue(
            label: "\(Self.callbackQueueLabel).\(UUID().uuidString)"
        )
    }

    /// Connects the accepted socket and authenticates the first WebSocket
    /// message. The hello is intentionally a message body, never a URL query
    /// parameter, so proxies and browser history cannot capture the token.
    func prepare() async throws {
        let handshakeTimeoutSleep = self.handshakeTimeoutSleep
        let hello = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.connect()
                return try await self.receiveWebSocketMessage()
            }
            group.addTask {
                try await handshakeTimeoutSleep()
                throw WebClientWebSocketTransportError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw WebClientWebSocketTransportError.timedOut
            }
            return first
        }
        guard let object = try? JSONSerialization.jsonObject(with: hello) as? [String: Any],
              object["type"] as? String == "cmux.web.hello" else {
            throw WebClientWebSocketTransportError.invalidHello
        }
        let receivedProtocol = object["protocol"] as? String
        let receivedVersion = object["protocol_version"] as? Int
        guard Self.validatesProtocol(receivedProtocol, version: receivedVersion) else {
            throw WebClientWebSocketTransportError.protocolMismatch(
                expected: Self.protocolIdentifier,
                received: receivedProtocol
            )
        }
        guard let token = object["token"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let grantID = await grantStore.authenticate(token: token) else {
            throw WebClientWebSocketTransportError.invalidToken
        }
        authenticatedGrant = grantID
        let acknowledgement: [String: Any] = [
            "type": "cmux.web.ready",
            "protocol": Self.protocolIdentifier,
            "protocol_version": Self.protocolVersion,
            "connection_id": UUID().uuidString,
            "grant_id": grantID.uuidString,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: acknowledgement) else {
            throw WebClientWebSocketTransportError.sendFailed("failed to encode hello acknowledgement")
        }
        try await sendWebSocketMessage(data)
    }

    /// The grant selected by the hello. Available only after ``prepare``.
    func authenticatedGrantID() -> UUID? {
        authenticatedGrant
    }

    func connect() async throws {
        try await withTaskCancellationHandler {
            switch state {
            case .ready:
                return
            case .closed:
                throw WebClientWebSocketTransportError.closed
            case .failed:
                throw stateError ?? WebClientWebSocketTransportError.notReady
            case .connecting:
                try await withCheckedThrowingContinuation { continuation in
                    connectWaiters.append(continuation)
                }
            case .idle:
                try await withCheckedThrowingContinuation { continuation in
                    connectWaiters.append(continuation)
                    state = .connecting
                    connection.stateUpdateHandler = { [weak self] nextState in
                        guard let self else { return }
                        Task { await self.handleConnectionState(nextState) }
                    }
                    connection.start(queue: callbackQueue)
                }
            }
        } onCancel: {
            Task { await self.close() }
        }
    }

    func receive() async throws -> Data? {
        guard state == .ready else {
            if case .closed = state { return nil }
            throw WebClientWebSocketTransportError.notReady
        }
        let payload = try await receiveWebSocketMessage()
        let decodedObject = try? JSONSerialization.jsonObject(with: payload)
        let object = decodedObject as? [String: Any]
        guard Self.validatesMessageProtocol(object) else {
            if let response = object {
                let error = MobileHostRPCEnvelope.error(
                    id: response["id"],
                    code: "protocol_mismatch",
                    message: "Expected \(Self.protocolIdentifier)"
                )
                try? await sendWebSocketMessage(error)
            }
            throw WebClientWebSocketTransportError.protocolMismatch(
                expected: Self.protocolIdentifier,
                received: object?["protocol"] as? String
            )
        }
        return try MobileSyncFrameCodec.encodeFrame(payload)
    }

    func send(_ data: Data) async throws {
        guard state == .ready else {
            throw WebClientWebSocketTransportError.notReady
        }
        sendBuffer.append(data)
        let frames: [Data]
        do {
            frames = try MobileSyncFrameCodec.decodeFrames(from: &sendBuffer)
        } catch {
            sendBuffer.removeAll(keepingCapacity: false)
            throw WebClientWebSocketTransportError.sendFailed("invalid response frame")
        }
        for frame in frames {
            // Frames are already JSON wire payloads. Forward them byte-for-byte;
            // terminal.bytes selects its browser sequence variant during
            // producer fan-out, so this PTY hot path never parses or re-encodes JSON.
            try await sendWebSocketMessage(frame)
        }
    }

    func close() async {
        guard state != .closed else { return }
        state = .closed
        connection.stateUpdateHandler = nil
        connection.cancel()
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: WebClientWebSocketTransportError.closed)
        }
        receiveWaiter?.resume(throwing: WebClientWebSocketTransportError.closed)
        receiveWaiter = nil
        sendBuffer.removeAll(keepingCapacity: false)
        failAllSends(WebClientWebSocketTransportError.closed)
    }

    private func handleConnectionState(_ nextState: NWConnection.State) {
        switch nextState {
        case .ready:
            guard state == .connecting else { return }
            state = .ready
            let waiters = connectWaiters
            connectWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        case .failed(let error):
            guard state != .closed else { return }
            let wrapped = WebClientWebSocketTransportError.receiveFailed(error.localizedDescription)
            state = .failed
            stateError = wrapped
            let waiters = connectWaiters
            connectWaiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: wrapped) }
            receiveWaiter?.resume(throwing: wrapped)
            receiveWaiter = nil
            failAllSends(wrapped)
        case .waiting:
            // An accepted WebSocket can briefly park in waiting while the
            // protocol stack completes its upgrade; the hello deadline owns
            // the eventual failure if it never becomes ready.
            break
        case .cancelled:
            Task { await close() }
        default:
            break
        }
    }

    private func receiveWebSocketMessage() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard receiveWaiter == nil else {
                    continuation.resume(throwing: WebClientWebSocketTransportError.receiveFailed("concurrent receive"))
                    return
                }
                receiveWaiter = continuation
                connection.receiveMessage { [weak self] data, _, _, error in
                    guard let self else { return }
                    Task {
                        await self.finishReceive(data: data, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.close() }
        }
    }

    private func finishReceive(data: Data?, error: NWError?) {
        guard let waiter = receiveWaiter else { return }
        receiveWaiter = nil
        if let error {
            waiter.resume(throwing: WebClientWebSocketTransportError.receiveFailed(error.localizedDescription))
        } else if let data, data.count <= Self.maximumClientMessageByteCount {
            waiter.resume(returning: data)
        } else if data != nil {
            waiter.resume(throwing: WebClientWebSocketTransportError.receiveFailed("WebSocket message too large"))
        } else {
            waiter.resume(throwing: WebClientWebSocketTransportError.closed)
        }
    }

    private func sendWebSocketMessage(_ data: Data) async throws {
        guard data.count <= Self.maximumServerMessageByteCount else {
            throw WebClientWebSocketTransportError.sendFailed("WebSocket message too large")
        }
        let sendID = UUID()
        let sendTimeoutSleep = self.sendTimeoutSleep
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingSendWaiters[sendID] = continuation
                pendingSendTimeoutTasks[sendID] = Task { [weak self, sendTimeoutSleep] in
                    do {
                        try await sendTimeoutSleep()
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await self?.sendTimedOut(sendID)
                }
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(
                    identifier: "cmux.web.message",
                    metadata: [metadata]
                )
                connection.send(
                    content: data,
                    contentContext: context,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        let wrapped = error.map {
                            WebClientWebSocketTransportError.sendFailed($0.localizedDescription)
                        }
                        Task { _ = await self.finishSend(sendID, error: wrapped) }
                    }
                )
            }
        } onCancel: {
            Task { await self.cancelSend(sendID) }
        }
    }

    @discardableResult
    private func finishSend(_ id: UUID, error: Error?) -> Bool {
        guard let waiter = pendingSendWaiters.removeValue(forKey: id) else { return false }
        pendingSendTimeoutTasks.removeValue(forKey: id)?.cancel()
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
        return true
    }

    private func sendTimedOut(_ id: UUID) async {
        guard finishSend(
            id,
            error: WebClientWebSocketTransportError.sendFailed("WebSocket send timed out")
        ) else { return }
        await close()
    }

    private func cancelSend(_ id: UUID) async {
        guard finishSend(id, error: WebClientWebSocketTransportError.closed) else { return }
        await close()
    }

    private func failAllSends(_ error: Error) {
        let senders = Array(pendingSendWaiters.values)
        pendingSendWaiters.removeAll()
        let timeouts = Array(pendingSendTimeoutTasks.values)
        pendingSendTimeoutTasks.removeAll()
        for timeout in timeouts { timeout.cancel() }
        for sender in senders { sender.resume(throwing: error) }
    }

}
