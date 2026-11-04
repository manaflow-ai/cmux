import Foundation
import Network

/// Owns one Network.framework WebSocket so reconnects do not retain CFNetwork tasks.
actor WorkspacePresenceSocket: WorkspacePresenceConnection {
    // NWConnection does not expose rejected-upgrade status/headers, so use a
    // bounded floor for pre-ready failures instead of retrying at one second.
    private static let minimumUpgradeRetryDelay: TimeInterval = 15

    private enum Message {
        case data(Data)
        case text(String)
    }

    private nonisolated let connection: NWConnection
    private var receiver: CheckedContinuation<Message, any Error>?
    private var closed = false
    private var failure: (any Error)?
    private var revision: UInt64 = 0
    private var ready = false
    private var upgradeTimeoutTask: Task<Void, Never>?

    init(request: URLRequest) throws {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            throw URLError(.badURL)
        }

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        webSocketOptions.maximumMessageSize = 512 * 1024
        if let headers = request.allHTTPHeaderFields {
            webSocketOptions.setAdditionalHeaders(headers.map { (name: $0.key, value: $0.value) })
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = max(1, Int(request.timeoutInterval.rounded(.up)))
        let parameters: NWParameters
        if scheme == "wss" {
            parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcpOptions)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(state: state) }
        }
        connection.start(queue: DispatchQueue(label: "com.cmux.workspace-presence.websocket", qos: .utility))

    }

    func startUpgradeTimeout(_ timeout: TimeInterval) {
        guard !ready, !closed else { return }
        upgradeTimeoutTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(timeout))
            } catch {
                return
            }
            await self?.handleUpgradeTimeout()
        }
    }

    deinit {
        upgradeTimeoutTask?.cancel()
        connection.cancel()
    }

    func receive() async throws -> WorkspacePresenceSnapshot {
        let message = try await receiveMessage()
        let data: Data
        switch message {
        case .data(let value): data = value
        case .text(let value): data = Data(value.utf8)
        }
        return try JSONDecoder().decode(WorkspacePresenceSnapshot.self, from: data)
    }

    func sendViewing(_ active: Bool, revision next: UInt64) async throws {
        guard next >= revision else { return }
        revision = next
        let payload = active ? #"{"type":"view","active":true}"# : #"{"type":"view","active":false}"#
        try await sendMessage(Data(payload.utf8))
    }

    nonisolated func close() {
        connection.cancel()
    }

    private func receiveMessage() async throws -> Message {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Message, any Error>) in
                guard receiver == nil else {
                    continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
                    return
                }
                if let failure {
                    continuation.resume(throwing: failure)
                    return
                }
                if closed {
                    continuation.resume(throwing: URLError(.networkConnectionLost))
                    return
                }
                receiver = continuation
                receiveNextMessage()
            }
        } onCancel: {
            close()
        }
    }

    private func receiveNextMessage() {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
            Task { await self?.handle(data: data, opcode: opcode, isComplete: isComplete, error: error) }
        }
    }

    private func sendMessage(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !closed else {
                    continuation.resume(throwing: failure ?? URLError(.networkConnectionLost))
                    return
                }
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "workspace-presence.send", metadata: [metadata])
                connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            close()
        }
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            cancelUpgradeTimeout()
        case .waiting(_) where !ready:
            cancelUpgradeTimeout()
            fail(WorkspacePresenceError.retryAfter(Self.minimumUpgradeRetryDelay))
            connection.cancel()
        case .failed(_) where !ready:
            cancelUpgradeTimeout()
            fail(WorkspacePresenceError.retryAfter(Self.minimumUpgradeRetryDelay))
            connection.cancel()
        case .failed(let error):
            cancelUpgradeTimeout()
            fail(error)
            connection.cancel()
        case .cancelled:
            cancelUpgradeTimeout()
            fail(URLError(.networkConnectionLost))
        default:
            break
        }
    }

    private func handleUpgradeTimeout() {
        guard !ready, !closed else { return }
        upgradeTimeoutTask = nil
        fail(WorkspacePresenceError.retryAfter(Self.minimumUpgradeRetryDelay))
        connection.cancel()
    }

    private func cancelUpgradeTimeout() {
        upgradeTimeoutTask?.cancel()
        upgradeTimeoutTask = nil
    }

    private func handle(data: Data?, opcode: NWProtocolWebSocket.Opcode?, isComplete: Bool, error: NWError?) {
        if let error {
            fail(error)
            return
        }
        if isComplete, data == nil, opcode == nil {
            fail(URLError(.networkConnectionLost))
            return
        }
        guard let receiver else { return }
        switch opcode {
        case .binary:
            self.receiver = nil
            receiver.resume(returning: .data(data ?? Data()))
        case .text:
            self.receiver = nil
            receiver.resume(returning: .text(String(decoding: data ?? Data(), as: UTF8.self)))
        case .close:
            fail(URLError(.networkConnectionLost))
        default:
            receiveNextMessage()
        }
    }

    private func fail(_ error: any Error) {
        guard !closed else { return }
        closed = true
        failure = error
        receiver?.resume(throwing: error)
        receiver = nil
    }
}
