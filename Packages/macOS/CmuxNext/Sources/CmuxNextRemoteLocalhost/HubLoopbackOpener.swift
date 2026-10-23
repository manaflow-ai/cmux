import Foundation
import Network

/// Opens a Cloud machine's loopback through the app's own WireGuard tunnel:
/// SOCKS5 on the `cmux-tui wg hub` socket (`CloudTunnelHub`, enrolled for
/// this Mac with `POST /api/vm/tunnel`) to the machine's private address.
/// It stands in for the daemon's loopback forward on a machine whose
/// cmux-tui predates it, as cmux Classic reaches a machine's desktop: only
/// this process dials, behind `RemoteLocalhostProxy`'s peer check, and no
/// port opens on this Mac. Only loopback hosts map; anything else refuses.
public struct HubLoopbackOpener: LoopbackTunnelOpening {
    /// The hub's SOCKS socket, starting the hub when it is not running.
    public typealias SocketPath = @Sendable () async throws -> String

    private let socketPath: SocketPath
    private let address: IPv4Address
    private let handshakeTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    // concurrency-allow: Network.framework requires an event-delivery queue; it protects no mutable Swift state.
    private let queue = DispatchQueue(label: "com.cmuxterm.next.cloud-hub-loopback", qos: .userInitiated)

    /// - Parameters:
    ///   - socketPath: The hub's SOCKS socket path (`CloudTunnelHub.socketPath()`).
    ///   - address: The machine's private IPv4 address on its Cloud network; nil for any other value.
    public init?(socketPath: @escaping SocketPath, address: String, handshakeTimeout: Duration = .seconds(10)) {
        self.init(socketPath: socketPath, address: address, handshakeTimeout: handshakeTimeout, sleep: { duration in
            // wakeup-allow: one bounded, cancellable network-handshake deadline; tests inject this clock.
            try await ContinuousClock().sleep(for: duration)
        })
    }

    /// Test seam for the one-shot handshake deadline.
    init?(socketPath: @escaping SocketPath, address: String, handshakeTimeout: Duration,
          sleep: @escaping @Sendable (Duration) async throws -> Void) {
        guard let parsed = IPv4Address(address) else { return nil }
        self.socketPath = socketPath
        self.address = parsed
        self.handshakeTimeout = handshakeTimeout
        self.sleep = sleep
    }

    public func openTunnel(host: String, port: UInt16) async throws(LoopbackTunnelFailure) -> any LoopbackTunnel {
        guard LoopbackHost(host).isLoopback else { throw .other("Only the machine's localhost goes through the Cloud tunnel") }
        let path: String
        do { path = try await socketPath() } catch { throw .unavailable("Cloud tunnel unavailable") }
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        do {
            return try await withTaskCancellationHandler {
                guard await connection.ready(on: queue) else { throw LoopbackTunnelFailure.unavailable("Cloud tunnel unavailable") }
                try await handshake(connection, port: port)
                return CloudProxyLoopbackTunnel(connection: connection, initialData: Data())
            } onCancel: {
                connection.cancel()
            }
        } catch let failure as LoopbackTunnelFailure {
            connection.cancel()
            throw failure
        } catch {
            connection.cancel()
            throw .other("Cloud tunnel connection failed")
        }
    }

    /// SOCKS5 with no authentication (the hub's socket is this user's own),
    /// then CONNECT to the machine's address, bounded by `handshakeTimeout`.
    private func handshake(_ connection: NWConnection, port: UInt16) async throws(LoopbackTunnelFailure) {
        let address = address, timeout = handshakeTimeout, sleep = sleep
        do {
            // concurrency-allow: the injected sleeper honors cancellation and the timeout cancels NWConnection, so both children exit.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await Self.negotiate(connection, address: address, port: port) }
                group.addTask {
                    // wakeup-allow: the handshake's one-shot deadline, not polling or settling.
                    try await sleep(timeout)
                    connection.cancel()
                    throw LoopbackTunnelFailure.other("Cloud tunnel handshake timed out")
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch let failure as LoopbackTunnelFailure {
            throw failure
        } catch {
            throw .other("Cloud tunnel connection failed")
        }
    }

    private static func negotiate(_ connection: NWConnection, address: IPv4Address, port: UInt16) async throws {
        try await connection.sendAll(Data([0x05, 0x01, 0x00]))
        guard try await read(2, from: connection) == Data([0x05, 0x00]) else {
            throw LoopbackTunnelFailure.other("Cloud tunnel refused the handshake")
        }
        var request = Data([0x05, 0x01, 0x00, 0x01])
        request.append(address.rawValue)
        request.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xFF)])
        try await connection.sendAll(request)
        // VER REP RSV ATYP, then an IPv4 bound address and port (the hub answers ATYP 1).
        let reply = try await read(10, from: connection)
        guard reply[reply.startIndex] == 0x05 else { throw LoopbackTunnelFailure.other("Cloud tunnel answered out of protocol") }
        switch reply[reply.startIndex + 1] {
        case 0x00: return
        case 0x05: throw LoopbackTunnelFailure.refused
        case 0x03, 0x04: throw LoopbackTunnelFailure.unavailable("The Cloud machine cannot be reached")
        default: throw LoopbackTunnelFailure.other("Cloud tunnel refused the connection")
        }
    }

    /// Exactly `count` bytes, or a throw when the hub ends first.
    private static func read(_ count: Int, from connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let (chunk, complete) = try await connection.receiveChunk(max: count - buffer.count)
            if let chunk { buffer.append(chunk) }
            if complete, buffer.count < count { throw LoopbackTunnelFailure.unavailable("Cloud tunnel ended the connection") }
        }
        return buffer
    }
}
