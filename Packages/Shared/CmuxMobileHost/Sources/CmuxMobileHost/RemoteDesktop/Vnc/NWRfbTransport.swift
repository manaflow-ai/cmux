public import CmuxRemoteDesktop
public import Foundation
import Network

/// TCP to a VNC server with Network.framework.
public final class NWRfbTransport: RfbTransport, @unchecked Sendable {
    // Justification: NWConnection is thread safe and runs its callbacks on
    // `queue`; this class holds no other mutable state.
    private let connection: NWConnection
    // Justification: NWConnection requires a callback queue.
    private let queue = DispatchQueue(label: "cmux.mobile.rd-vnc", qos: .userInteractive)

    private init(connection: NWConnection) {
        self.connection = connection
    }

    /// Connects, or throws when the connection fails or waits for a network.
    public static func connect(to address: VncAddress) async throws -> NWRfbTransport {
        guard let port = NWEndpoint.Port(rawValue: UInt16(address.port)) else { throw RfbError.closed }
        let transport = NWRfbTransport(connection: NWConnection(host: NWEndpoint.Host(address.host), port: port, using: .tcp))
        try await transport.start()
        return transport
    }

    private func start() async throws {
        let (states, continuation) = AsyncStream.makeStream(of: NWConnection.State.self)
        connection.stateUpdateHandler = { continuation.yield($0) }
        connection.start(queue: queue)
        defer {
            connection.stateUpdateHandler = nil
            continuation.finish()
        }
        for await state in states {
            switch state {
            case .ready: return
            case .failed, .waiting, .cancelled:
                connection.cancel()
                throw RfbError.closed
            default: continue
            }
        }
        throw RfbError.closed
    }

    public func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? RfbError.closed)
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    public func close() async {
        connection.cancel()
    }
}
