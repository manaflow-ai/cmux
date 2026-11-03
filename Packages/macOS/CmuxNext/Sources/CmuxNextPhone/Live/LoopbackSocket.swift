import Foundation
import Network

/// The seam between Network.framework's callbacks and the main actor for a loopback-only
/// TCP listener and its connections (``SimulatorSurfaceServer``). Every listener and
/// connection here is started on queue `.main`, so Network calls each handler on the main
/// thread; this type is the only place that asserts it.
@MainActor
final class LoopbackListener {
    private let listener: NWListener
    /// The port once the listener is ready (nil before, and after a failure).
    private(set) var port: UInt16?

    /// Listens on `127.0.0.1` (local connections only). `ready` runs once with the port or
    /// the error; `accept` runs for each new connection.
    init(ready: @escaping @MainActor (Result<UInt16, any Error>) -> Void,
         accept: @escaping @MainActor (LoopbackConnection) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
        var answered = false
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { // main-proof: listener.start(queue: .main) below
                guard let self else { return }
                switch state {
                case .ready:
                    guard !answered, let port = self.listener.port?.rawValue else { return }
                    answered = true
                    self.port = port
                    ready(.success(port))
                case .failed(let error):
                    self.port = nil
                    if !answered { answered = true }
                    ready(.failure(error))
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { accept(LoopbackConnection(connection)) } // main-proof: listener.start(queue: .main) below
        }
        listener.start(queue: .main)
    }

    func cancel() {
        listener.cancel()
    }
}

/// One loopback connection, its callbacks delivered on the main actor (started on `.main`).
@MainActor
final class LoopbackConnection: Sendable {
    private nonisolated let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Starts the connection; `ended` runs when it fails or is cancelled.
    func start(ended: @escaping @MainActor () -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: MainActor.assumeIsolated { ended() } // main-proof: connection.start(queue: .main) below
            default: break
            }
        }
        connection.start(queue: .main)
    }

    /// Reads what is there (up to `maximum` bytes): `data`, and whether the peer finished or failed.
    func receive(maximum: Int, _ handler: @escaping @MainActor (Data?, Bool) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
            MainActor.assumeIsolated { handler(data, complete || error != nil) } // main-proof: connection.start(queue: .main)
        }
    }

    /// Sends `data` in order; `sent` runs on the main actor once it is out.
    func send(_ data: Data, sent: (@MainActor () -> Void)? = nil) {
        connection.send(content: data, completion: .contentProcessed { _ in
            guard let sent else { return }
            MainActor.assumeIsolated { sent() } // main-proof: connection.start(queue: .main)
        })
    }

    /// Sends `data` from any thread (VideoToolbox's); Network keeps the order of sends.
    nonisolated func sendFromAnyThread(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection.cancel()
    }
}
