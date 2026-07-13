import CMUXMobileCore
import Foundation
@preconcurrency import Network
@testable import CmuxMobileTransport

final class WebSocketEchoServer: @unchecked Sendable {
    // Wraps NWListener/NWConnection; every mutation happens on `queue`.
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.cmux.mobile.websocket-echo-server")
    private var readyContinuation: CheckedContinuation<UInt16, any Error>?
    private var connections: [NWConnection] = []

    init() throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.readyContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            for connection in self.connections {
                connection.cancel()
            }
            self.connections.removeAll()
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else {
                readyContinuation?.resume(throwing: CmxNetworkByteTransportError.invalidPort(0))
                readyContinuation = nil
                return
            }
            readyContinuation?.resume(returning: port)
            readyContinuation = nil
        case let .failed(error):
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
        case .cancelled:
            readyContinuation?.resume(throwing: CancellationError())
            readyContinuation = nil
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receiveMessage(on: connection)
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, isComplete, error in
            guard let self, let connection else {
                return
            }
            if let data {
                self.sendEcho(data, context: context, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveMessage(on: connection)
        }
    }

    private func sendEcho(
        _ data: Data,
        context: NWConnection.ContentContext?,
        on connection: NWConnection
    ) {
        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata
        let opcode = metadata?.opcode ?? .binary
        let responseMetadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let responseContext = NWConnection.ContentContext(
            identifier: "websocket-echo",
            metadata: [responseMetadata]
        )
        connection.send(
            content: data,
            contentContext: responseContext,
            isComplete: true,
            completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection else {
                    return
                }
                if error != nil {
                    connection.cancel()
                    return
                }
                self.receiveMessage(on: connection)
            }
        )
    }
}
