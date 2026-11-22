import CmuxNextWakeups
import Foundation
import Network
import Synchronization

/// One browser connection to the proxy: read the head, check the route
/// credential, then tunnel to the machine (loopback) or connect directly
/// (everything else, with the loopback guard), and relay bytes both ways.
final class ProxyConnection: Sendable {
    static let headDeadline: Duration = .seconds(10)
    static let chunkBytes = 64 * 1024

    private let client: NWConnection
    private let proxy: RemoteLocalhostProxy
    private let localPort: UInt16
    private let machineListener: Bool
    private let deadline = DemandTimer(owner: "RemoteLocalhostProxy.head")

    init(client: NWConnection, proxy: RemoteLocalhostProxy, localPort: UInt16, machineListener: Bool) {
        self.client = client
        self.proxy = proxy
        self.localPort = localPort
        self.machineListener = machineListener
    }

    /// A machine listener's route when the peer is this app or its helpers.
    private func trustedRoute() -> RemoteLocalhostProxy.Route? {
        guard machineListener, case .hostPort(_, let peer) = client.endpoint,
              PeerProcess.isTrusted(peerPort: peer.rawValue, localPort: localPort) else { return nil }
        return proxy.route(forListenerPort: localPort)
    }

    func start() {
        client.start(queue: proxy.queue)
        // task-owner: one task per proxied connection; it ends when either side closes
        Task { await self.run() }
    }

    private func run() async {
        defer {
            client.cancel()
            proxy.connectionEnded()
        }
        let client = client
        deadline.schedule(after: Self.headDeadline) { client.cancel() }
        guard let (head, rest) = await readHead() else {
            deadline.cancel()
            return
        }
        deadline.cancel()
        guard let route = trustedRoute() ?? proxy.route(forAuthorization: head.proxyAuthorization) else {
            proxy.count(\.unauthorized)
            proxy.note("407 \(head.kind == .connect ? "CONNECT" : head.method) \(head.host):\(head.port) credential=\(head.proxyAuthorization == nil ? "none" : "wrong")")
            try? await client.sendAll(ProxyResponses.authenticationRequired)
            return
        }
        if LoopbackHost(head.host).isLoopback {
            await tunnel(head, rest: rest, route: route)
        } else {
            await direct(head, rest: rest)
        }
    }

    /// Reads until a full head; nil when the client left or sent garbage.
    private func readHead() async -> (ProxyRequestHead, Data)? {
        var buffer = Data()
        // wakeup-allow: each iteration awaits the next received chunk; EOF, errors and the head deadline end it
        while true {
            guard let (chunk, complete) = try? await client.receiveChunk(max: Self.chunkBytes) else { return nil }
            if let chunk { buffer.append(chunk) }
            do {
                let (head, used) = try ProxyRequestHead.parse(buffer)
                return (head, Data(buffer[(buffer.startIndex + used)...]))
            } catch .incomplete {
                if complete { return nil }
            } catch .unsupportedScheme {
                try? await client.sendAll(ProxyResponses.status(501, "Not Implemented"))
                return nil
            } catch {
                try? await client.sendAll(ProxyResponses.status(400, "Bad Request"))
                return nil
            }
        }
    }

    // MARK: Loopback: the machine

    private func tunnel(_ head: ProxyRequestHead, rest: Data, route: RemoteLocalhostProxy.Route) async {
        let tunnel: any LoopbackTunnel
        do {
            tunnel = try await route.opener.openTunnel(host: head.host, port: head.port)
        } catch {
            proxy.count(\.failures)
            proxy.note("tunnel \(head.host):\(head.port) failed: \(error)")
            let page = ProxyErrorPage(host: head.host, port: head.port, machine: route.machineName, failure: error)
            try? await client.sendAll(head.kind == .forward ? page.response() : ProxyResponses.status(502, "Bad Gateway"))
            return
        }
        proxy.count(\.tunnels)
        proxy.note("tunnel \(head.host):\(head.port) to \(route.machineName)")
        do {
            switch head.kind {
            case .connect:
                try await client.sendAll(ProxyResponses.connectionEstablished)
                if !rest.isEmpty { try await tunnel.write(rest) }
            case .forward:
                try await tunnel.write(head.originHead() + rest)
            }
        } catch {
            tunnel.close()
            return
        }
        await relay(tunnel)
    }

    private func relay(_ tunnel: any LoopbackTunnel) async {
        let client = client
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // Browser to machine; EOF half-closes.
                // wakeup-allow: each iteration awaits the next received chunk; EOF and errors end it
                while true {
                    guard let (chunk, complete) = try? await client.receiveChunk(max: Self.chunkBytes) else {
                        tunnel.close()
                        return
                    }
                    if let chunk, !chunk.isEmpty {
                        do { try await tunnel.write(chunk) } catch { return }
                    }
                    if complete {
                        tunnel.shutdownWrite()
                        return
                    }
                }
            }
            group.addTask {
                // Machine to browser; ends the connection when the tunnel ends.
                for await event in tunnel.events {
                    switch event {
                    case .data(let data):
                        do {
                            try await client.sendAll(data)
                            tunnel.consumed(data.count)
                        } catch {
                            tunnel.close()
                            return
                        }
                    case .eof:
                        try? await client.sendFinal()
                    case .closed:
                        client.cancel()
                        return
                    }
                }
            }
        }
    }

    // MARK: Everything else: direct from this Mac

    private func direct(_ head: ProxyRequestHead, rest: Data) async {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        tcp.noDelay = true
        guard let port = NWEndpoint.Port(rawValue: head.port) else { return }
        let upstream = NWConnection(host: proxy.directHost(head.host), port: port, using: NWParameters(tls: nil, tcp: tcp))
        defer { upstream.cancel() }
        guard await upstream.ready(on: proxy.queue) else {
            proxy.count(\.failures)
            try? await client.sendAll(ProxyResponses.status(502, "Bad Gateway"))
            return
        }
        // A public name that resolved to this Mac's loopback: refuse, so a
        // page served by the remote machine cannot reach this Mac.
        if case .hostPort(let host, _)? = upstream.currentPath?.remoteEndpoint, Self.isLocalOnly(host) {
            proxy.count(\.refusedLocal)
            proxy.note("refused \(head.host):\(head.port): resolves to this Mac")
            proxy.logger.info("remote-localhost refused \(head.host, privacy: .public): resolves to this Mac")
            try? await client.sendAll(ProxyResponses.status(403, "Forbidden"))
            return
        }
        proxy.count(\.direct)
        do {
            switch head.kind {
            case .connect:
                try await client.sendAll(ProxyResponses.connectionEstablished)
                if !rest.isEmpty { try await upstream.sendAll(rest) }
            case .forward:
                try await upstream.sendAll(head.originHead() + rest)
            }
        } catch {
            return
        }
        let client = client
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.pipe(from: client, to: upstream) }
            group.addTask { await Self.pipe(from: upstream, to: client) }
        }
    }

    private static func isLocalOnly(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): address.isLocalOnly
        case .ipv6(let address): address.isLocalOnly
        case .name: false
        @unknown default: false
        }
    }

    /// Copies until EOF (then half-closes `destination`) or an error (then
    /// cancels both).
    private static func pipe(from source: NWConnection, to destination: NWConnection) async {
        // wakeup-allow: each iteration awaits the next received chunk; EOF and errors end it
        while true {
            guard let (chunk, complete) = try? await source.receiveChunk(max: chunkBytes) else {
                destination.cancel()
                return
            }
            if let chunk, !chunk.isEmpty {
                do { try await destination.sendAll(chunk) } catch {
                    source.cancel()
                    return
                }
            }
            if complete {
                try? await destination.sendFinal()
                return
            }
        }
    }
}

/// Fixed proxy responses.
enum ProxyResponses {
    static let connectionEstablished = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)

    static let authenticationRequired = Data((
        "HTTP/1.1 407 Proxy Authentication Required\r\n"
            + "Proxy-Authenticate: Basic realm=\"cmux\"\r\n"
            + "Content-Length: 0\r\nConnection: close\r\n\r\n"
    ).utf8)

    static func status(_ code: Int, _ reason: String) -> Data {
        Data("HTTP/1.1 \(code) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }
}

extension NWConnection {
    /// The next chunk and whether the peer finished sending. Throws on a
    /// connection error.
    func receiveChunk(max: Int) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    func sendAll(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Half-closes the write side (TCP FIN).
    func sendFinal() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Starts the connection and waits for ready (true) or failure (false).
    func ready(on queue: DispatchQueue) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            stateUpdateHandler = { state in
                let outcome: Bool? = switch state {
                case .ready: true
                case .failed, .cancelled: false
                case .waiting: false
                default: nil
                }
                guard let outcome, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: outcome)
            }
            start(queue: queue)
        }
    }
}
