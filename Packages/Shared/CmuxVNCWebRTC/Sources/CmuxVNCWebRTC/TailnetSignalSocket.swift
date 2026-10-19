import Foundation
import Network

/// The signaling WebSocket to a host's tailnet port (remote-desktop-v2.md,
/// RD2-4). Plain WebSocket: WireGuard encrypts the link and the host names
/// this device with Tailscale WhoIs. The host refuses any handshake that
/// carries a browser `Origin` header; Network.framework's WebSocket client
/// sends only the handshake's own headers, and this socket adds none.
///
/// Network.framework rather than URLSession: it also dials a Unix socket
/// (a daemon forward can be one), and App Transport Security does not apply
/// to a plain `ws://` MagicDNS name.
final class TailnetSignalSocket: SignalChannel, @unchecked Sendable {
    // @unchecked: NWConnection is thread-safe; `started` is behind `lock`.
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "cmux.screen.tailnet-signal")
    private let lock = NSLock()
    private var started = false

    /// Keepalive for an idle link: TCP keepalive (no timer here); the host
    /// also pings every 20 s and Network.framework answers its pings.
    private static let keepaliveIdleSeconds = 20

    /// `host:port` through the system Tailscale interface.
    convenience init(host: String, port: UInt16) {
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 4180))
    }

    /// A local endpoint that the daemon forwards to the host.
    convenience init(local: TailnetLocalEndpoint) {
        switch local {
        case let .tcp(host, port):
            self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 4180))
        case let .unix(path):
            self.init(endpoint: .unix(path: path))
        }
    }

    private init(endpoint: NWEndpoint) {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 1 << 20
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = Self.keepaliveIdleSeconds
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        connection = NWConnection(to: endpoint, using: parameters)
    }

    func messages() -> AsyncThrowingStream<SignalMessage, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SignalMessage.self, throwing: (any Error).self)
        let first = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        guard first else {
            continuation.finish(throwing: TailnetSignalError.unreachable("messages() called twice"))
            return stream
        }
        let connection = self.connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive(into: continuation)
            case let .waiting(error), let .failed(error):
                // `waiting`: no route to the host now (tailnet down, host off).
                // A viewer reports that instead of waiting for the network.
                continuation.finish(throwing: TailnetSignalError.unreachable(error.debugDescription))
                connection.cancel()
            case .cancelled:
                continuation.finish()
            default:
                break
            }
        }
        continuation.onTermination = { _ in connection.cancel() }
        connection.start(queue: queue)
        return stream
    }

    private func receive(into continuation: AsyncThrowingStream<SignalMessage, any Error>.Continuation) {
        connection.receiveMessage { [weak self] content, context, _, error in
            if let error {
                continuation.finish(throwing: TailnetSignalError.unreachable(error.debugDescription))
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text?:
                if let content, let message = try? JSONDecoder().decode(SignalMessage.self, from: content) {
                    continuation.yield(message)
                }
            case .close?:
                continuation.finish()
                self?.connection.cancel()
                return
            default:
                break
            }
            guard let self else {
                continuation.finish()
                return
            }
            receive(into: continuation)
        }
    }

    func send(_ message: SignalMessage) async throws {
        let data = try JSONEncoder().encode(message)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "signal", metadata: [metadata])
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: TailnetSignalError.unreachable(error.debugDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func close() {
        connection.cancel()
    }
}
