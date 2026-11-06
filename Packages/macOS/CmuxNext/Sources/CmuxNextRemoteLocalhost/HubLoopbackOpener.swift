import CmuxNextCompat
import Foundation
import Network

/// Opens a Cloud machine's loopback through the app's own WireGuard tunnel:
/// SOCKS5 on the `cmux-tui wg hub` socket (`CloudTunnelHub`, enrolled for
/// this Mac with `POST /api/vm/tunnel`) to the machine's private address.
/// Open Desktop's route, as cmux Classic reaches a machine's desktop: the
/// app dials behind `RemoteLocalhostProxy`'s peer check, presents the hub's
/// client token, and no TCP port opens on this Mac. Only loopback hosts map;
/// anything else refuses.
public struct HubLoopbackOpener: LoopbackTunnelOpening {
    /// The running hub's SOCKS socket and the client token it requires. Its description leaves
    /// the token out.
    public struct Endpoint: Sendable, CustomStringConvertible {
        public let socket: String
        public let token: String

        public init(socket: String, token: String) {
            self.socket = socket
            self.token = token
        }

        public var description: String { "HubLoopbackOpener.Endpoint(socket: \(socket))" }
    }

    /// The hub's endpoint, starting the hub when it is not running.
    public typealias Hub = @Sendable () async throws -> Endpoint

    /// The refusal when the hub names a socket path that does not fit a Unix socket address (`sun_path`).
    static let socketPathTooLong = "Cloud tunnel unavailable: the hub's socket path is too long"

    private let hub: Hub
    private let address: IPv4Address
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    // concurrency-allow: Network.framework requires an event-delivery queue; it protects no mutable Swift state.
    private let queue = DispatchQueue(label: "com.cmuxterm.next.cloud-hub-loopback", qos: .userInitiated)

    /// - Parameters:
    ///   - hub: The hub's endpoint (`CloudTunnelHub.endpoint()`).
    ///   - address: The machine's private IPv4 address on its Cloud network; nil for any other value.
    ///   - timeout: The deadline over the whole open (starting the hub, connecting, the handshake).
    public init?(hub: @escaping Hub, address: String, timeout: Duration = .seconds(15)) {
        self.init(hub: hub, address: address, timeout: timeout, sleep: { duration in
            // wakeup-allow: one bounded, cancellable open deadline; tests inject this clock.
            try await ContinuousClock().sleep(for: duration)
        })
    }

    /// Test seam for the open's one-shot deadline.
    init?(hub: @escaping Hub, address: String, timeout: Duration,
          sleep: @escaping @Sendable (Duration) async throws -> Void) {
        guard let parsed = IPv4Address(address) else { return nil }
        self.hub = hub
        self.address = parsed
        self.timeout = timeout
        self.sleep = sleep
    }

    public func openTunnel(host: String, port: UInt16) async throws(LoopbackTunnelFailure) -> any LoopbackTunnel {
        guard LoopbackHost(host).isLoopback else { throw .other("Only the machine's localhost goes through the Cloud tunnel") }
        let hub = hub, address = address, queue = queue, timeout = timeout, sleep = sleep
        do {
            // concurrency-allow: the injected sleeper honors cancellation and cancelling the open cancels its NWConnection, so both children exit.
            return try await withThrowingTaskGroup(of: (any LoopbackTunnel)?.self) { group in
                group.addTask { try await Self.connect(hub: hub, address: address, port: port, queue: queue) }
                group.addTask {
                    // wakeup-allow: the open's one-shot deadline, not polling or settling.
                    try await sleep(timeout)
                    throw LoopbackTunnelFailure.other("Cloud tunnel handshake timed out")
                }
                defer { group.cancelAll() }
                guard let opened = try await group.next(), let tunnel = opened else {
                    throw LoopbackTunnelFailure.other("Cloud tunnel connection ended")
                }
                return tunnel
            }
        } catch let failure as LoopbackTunnelFailure {
            throw failure
        } catch {
            throw .other("Cloud tunnel connection failed")
        }
    }

    /// The hub's socket, a connection to it, then SOCKS5 CONNECT to the machine's address.
    private static func connect(hub: Hub, address: IPv4Address, port: UInt16,
                                queue: DispatchQueue) async throws -> (any LoopbackTunnel)? {
        let endpoint: Endpoint
        do { endpoint = try await hub() } catch { throw LoopbackTunnelFailure.unavailable("Cloud tunnel unavailable") }
        try Task.checkCancellation()
        // A socket path past sun_path traps in NWEndpoint.unix (#28492): no tunnel there.
        guard let socket = try? NWEndpoint.unixSocket(path: endpoint.socket) else {
            throw LoopbackTunnelFailure.unavailable(Self.socketPathTooLong)
        }
        let connection = NWConnection(to: socket, using: .tcp)
        do {
            return try await withTaskCancellationHandler {
                guard await connection.ready(on: queue) else { throw LoopbackTunnelFailure.unavailable("Cloud tunnel unavailable") }
                try await negotiate(connection, token: endpoint.token, address: address, port: port)
                let tunnel = CloudProxyLoopbackTunnel(connection: connection, initialData: Data())
                // Opened just as the deadline won: nobody takes this tunnel, so it closes here.
                if Task.isCancelled {
                    tunnel.close()
                    throw CancellationError()
                }
                return tunnel
            } onCancel: {
                connection.cancel()
            }
        } catch {
            connection.cancel()
            throw error
        }
    }

    /// SOCKS5 username/password (RFC 1929) carrying the hub's client token, then CONNECT.
    private static func negotiate(_ connection: NWConnection, token: String, address: IPv4Address, port: UInt16) async throws {
        let secret = Data(token.utf8)
        guard !secret.isEmpty, secret.count <= 255 else { throw LoopbackTunnelFailure.other("Cloud tunnel refused the handshake") }
        try await connection.sendAll(Data([0x05, 0x01, 0x02]))
        guard try await read(2, from: connection) == Data([0x05, 0x02]) else {
            throw LoopbackTunnelFailure.other("Cloud tunnel refused the handshake")
        }
        var auth = Data([0x01, 0x04])
        auth.append(contentsOf: Array("cmux".utf8))
        auth.append(UInt8(secret.count))
        auth.append(secret)
        try await connection.sendAll(auth)
        guard try await read(2, from: connection) == Data([0x01, 0x00]) else {
            throw LoopbackTunnelFailure.other("Cloud tunnel refused the handshake")
        }
        var request = Data([0x05, 0x01, 0x00, 0x01])
        request.append(address.rawValue)
        request.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xFF)])
        try await connection.sendAll(request)
        // VER REP RSV ATYP, then the bound address (its length set by ATYP) and port: all of it is
        // read here, so none reaches the page's stream.
        let reply = try await read(4, from: connection)
        guard reply[reply.startIndex] == 0x05 else { throw LoopbackTunnelFailure.other("Cloud tunnel answered out of protocol") }
        let bound: Int
        switch reply[reply.startIndex + 3] {
        case 0x01: bound = 4
        case 0x04: bound = 16
        case 0x03:
            let length = try await read(1, from: connection)
            bound = Int(length[length.startIndex])
        default: throw LoopbackTunnelFailure.other("Cloud tunnel answered out of protocol")
        }
        _ = try await read(bound + 2, from: connection)
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
