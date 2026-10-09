import Foundation
@preconcurrency import Network

/// A TCP server on 127.0.0.1 that echoes every byte and half-closes after
/// the client does. `received` counts bytes so tests can see back-pressure.
final class EchoServer: @unchecked Sendable {
    let listener: NWListener
    let port: UInt16
    private let queue = DispatchQueue(label: "c14.echo")

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> EchoServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "c14.echo.listener")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): if once.take() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                Self.echo(connection)
            }
            listener.start(queue: queue)
        }
        return EchoServer(listener: listener, port: port)
    }

    private static func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { _ in
                    if isComplete {
                        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                    } else {
                        echo(connection)
                    }
                })
            } else if isComplete || error != nil {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            } else {
                echo(connection)
            }
        }
    }

    func stop() {
        listener.cancel()
    }

    /// A port nothing listens on (bound, then released).
    static func closedPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return UInt16(bigEndian: address.sin_port)
    }
}

/// Lets exactly one caller through.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
