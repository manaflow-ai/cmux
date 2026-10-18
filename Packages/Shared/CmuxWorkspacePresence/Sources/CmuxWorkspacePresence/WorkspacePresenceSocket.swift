import Foundation
import Network

/// Owns one Network.framework WebSocket so reconnects do not retain CFNetwork tasks.
actor WorkspacePresenceSocket: WorkspacePresenceConnection {
    private enum Message {
        case data(Data)
        case text(String)
    }

    private nonisolated let connection: NWConnection
    private var receiver: CheckedContinuation<Message, any Error>?
    private var closed = false
    private var failure: (any Error)?
    private var revision: UInt64 = 0

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

        let parameters: NWParameters = scheme == "wss" ? .tls : .tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(state: state) }
        }
        connection.start(queue: DispatchQueue(label: "com.cmux.workspace-presence.websocket", qos: .utility))
    }

    deinit { connection.cancel() }

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
        connection.receiveMessage { [weak self] data, context, _, error in
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
            Task { await self?.handle(data: data, opcode: opcode, error: error) }
        }
    }

    private func sendMessage(_ data: Data) async throws {
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
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .failed(let error):
            fail(error)
        case .cancelled:
            fail(URLError(.networkConnectionLost))
        default:
            break
        }
    }

    private func handle(data: Data?, opcode: NWProtocolWebSocket.Opcode?, error: NWError?) {
        if let error {
            fail(error)
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
        closed = true
        failure = error
        receiver?.resume(throwing: error)
        receiver = nil
    }
}
