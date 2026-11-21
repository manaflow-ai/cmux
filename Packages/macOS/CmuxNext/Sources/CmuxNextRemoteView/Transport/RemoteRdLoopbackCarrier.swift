public import Foundation
import Network
import CmuxNextCompat

/// A TCP connection to a host on this Mac's loopback interface: the
/// development and local remote browser hosts (`RemoteRdLoopbackEndpoint`).
public nonisolated final class RemoteRdLoopbackCarrier: RemoteRdByteCarrier {
    private let connection: NWConnection
    private let handler = Mutex<(@Sendable (RemoteRdCarrierEvent) -> Void)?>(nil)

    public init(endpoint: RemoteRdLoopbackEndpoint) {
        let port = NWEndpoint.Port(rawValue: endpoint.port) ?? .any
        connection = NWConnection(host: NWEndpoint.Host.ipv4(.loopback), port: port, using: .tcp)
    }

    public func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void) {
        handler.store(events)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                emit(.ready)
                receiveNext()
            case let .failed(error):
                emit(.closed(reason: "loopback connection failed: \(error)"))
            case .cancelled:
                emit(.closed(reason: "loopback connection cancelled"))
            case let .waiting(error):
                // A loopback host that refuses the connection (no listener)
                // only makes the connection wait for a path change that never
                // comes: end the session so the viewer says why (cx-erey).
                emit(.closed(reason: "loopback host refused the connection: \(error)"))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ bytes: Data) {
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            self?.emit(.closed(reason: "loopback send failed: \(error)"))
        })
    }

    public func cancel() {
        handler.store(nil)
        connection.cancel()
    }

    private func emit(_ event: RemoteRdCarrierEvent) {
        handler.load()?(event)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { emit(.data(data)) }
            if let error {
                emit(.closed(reason: "loopback receive failed: \(error)"))
            } else if isComplete {
                emit(.closed(reason: "loopback host ended the stream"))
            } else {
                receiveNext()
            }
        }
    }
}
