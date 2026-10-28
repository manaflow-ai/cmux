public import Foundation
import Network
import CmuxNextCompat

/// A TCP connection to a host on this Mac's loopback interface: the
/// development and local remote browser hosts (`RemoteRdLoopbackEndpoint`).
///
/// The bytes handed to the connection that it has not processed count against ``sendBound``, as the
/// machine loopback carrier's outbox does: past it the carrier is backed up and the transport stops
/// producing until `.writable` (``RemoteRdByteCarrier``).
public nonisolated final class RemoteRdLoopbackCarrier: RemoteRdByteCarrier {
    /// The bytes the connection may hold unprocessed before the carrier is backed up: 4 MiB, as the
    /// machine loopback carrier's outbox.
    public static let sendBound = 4 << 20

    private let connection: NWConnection
    private let handler = Mutex<(@Sendable (RemoteRdCarrierEvent) -> Void)?>(nil)
    private let unsent: ByteCreditWindow

    public init(endpoint: RemoteRdLoopbackEndpoint, sendBound: Int = RemoteRdLoopbackCarrier.sendBound) {
        let port = NWEndpoint.Port(rawValue: endpoint.port) ?? .any
        connection = NWConnection(host: NWEndpoint.Host.ipv4(.loopback), port: port, using: .tcp)
        unsent = ByteCreditWindow(limit: sendBound)
    }

    public var isBackedUp: Bool { unsent.isPaused }

    public func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void) {
        handler.withLock { $0 = events }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                emit(.ready)
                receiveNext()
            case .failed, .cancelled:
                emit(.closed)
            case .waiting:
                // A loopback host that refuses the connection (no listener)
                // only makes the connection wait for a path change that never
                // comes: end the session so the viewer says why (cx-erey).
                emit(.closed)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ bytes: Data) {
        let count = bytes.count
        _ = unsent.produced(count)
        // The completion runs on the transport's queue (the connection's), the producer's context.
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else { return emit(.closed) }
            if unsent.consumed(count), unsent.resumeIfDrained() { emit(.writable) }
        })
    }

    public func cancel() {
        handler.withLock { $0 = nil }
        connection.cancel()
    }

    private func emit(_ event: RemoteRdCarrierEvent) {
        handler.withLock { $0 }?(event)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { emit(.data(data)) }
            if isComplete || error != nil {
                emit(.closed)
            } else {
                receiveNext()
            }
        }
    }
}
