import Foundation
import Network
import Synchronization
import Testing
@testable import CmuxNextRemoteLocalhost

/// The proxy end to end on 127.0.0.1: credentials, CONNECT and absolute-form
/// forwarding through a tunnel, the error page, and the loopback guard for
/// direct destinations. A local TCP server stands in for the machine's
/// dev server; `TCPTunnel` stands in for the daemon stream.
@Suite(.timeLimit(.minutes(1))) struct ProxyTests {
    @Test func requestsWithoutTheRouteCredentialGet407() async throws {
        let proxy = RemoteLocalhostProxy()
        let port = try await proxy.start()
        defer { proxy.stop() }
        _ = proxy.credential(for: "m", route: .init(machineName: "build-box", opener: FailingOpener(.refused)))
        let reply = try await RawClient.exchange(port: port, Data("CONNECT localhost:1 HTTP/1.1\r\n\r\n".utf8))
        #expect(reply.hasPrefix("HTTP/1.1 407 "))
        #expect(reply.contains("Proxy-Authenticate: Basic realm=\"cmux\""))
        #expect(proxy.stats.unauthorized == 1)
    }

    @Test func connectTunnelsBytesBothWays() async throws {
        let server = try await TestServer.start(mode: .echo)
        defer { server.stop() }
        let proxy = RemoteLocalhostProxy()
        let port = try await proxy.start()
        defer { proxy.stop() }
        let credential = proxy.credential(for: "m", route: .init(machineName: "build-box", opener: TCPOpener()))
        let head = "CONNECT localhost:\(server.port) HTTP/1.1\r\nProxy-Authorization: \(credential.basicAuthorization)\r\n\r\n"
        let reply = try await RawClient.exchange(port: port, Data(head.utf8), then: Data("ping-over-tunnel".utf8),
                                                 until: "ping-over-tunnel")
        #expect(reply.hasPrefix("HTTP/1.1 200 Connection Established\r\n\r\n"))
        #expect(reply.hasSuffix("ping-over-tunnel"))
        #expect(proxy.stats.tunnels == 1)
    }

    @Test func plainHTTPIsForwardedInOriginForm() async throws {
        let server = try await TestServer.start(mode: .http("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"))
        defer { server.stop() }
        let proxy = RemoteLocalhostProxy()
        let port = try await proxy.start()
        defer { proxy.stop() }
        let credential = proxy.credential(for: "m", route: .init(machineName: "build-box", opener: TCPOpener()))
        let head = "GET http://localhost:\(server.port)/app?x=1 HTTP/1.1\r\nHost: localhost:\(server.port)\r\n"
            + "Proxy-Authorization: \(credential.basicAuthorization)\r\nProxy-Connection: keep-alive\r\n\r\n"
        let reply = try await RawClient.exchange(port: port, Data(head.utf8), until: "hi")
        #expect(reply.hasPrefix("HTTP/1.1 200 OK"))
        #expect(reply.hasSuffix("\r\n\r\nhi"))
        let received = await server.firstRequest()
        #expect(received.hasPrefix("GET /app?x=1 HTTP/1.1\r\n"))
        #expect(!received.lowercased().contains("proxy-"), "credentials never reach the machine")
        #expect(received.contains("Connection: close\r\n"))
    }

    @Test func aFailedTunnelShowsAPageThatNamesTheMachine() async throws {
        let proxy = RemoteLocalhostProxy()
        let port = try await proxy.start()
        defer { proxy.stop() }
        let credential = proxy.credential(for: "m", route: .init(machineName: "build-box", opener: FailingOpener(.refused)))
        let head = "GET http://localhost:5173/ HTTP/1.1\r\nProxy-Authorization: \(credential.basicAuthorization)\r\n\r\n"
        let reply = try await RawClient.exchange(port: port, Data(head.utf8), until: "</html>")
        #expect(reply.hasPrefix("HTTP/1.1 502 Bad Gateway"))
        #expect(reply.contains("build-box"))
        #expect(reply.contains("localhost:5173"))

        let connect = "CONNECT localhost:5173 HTTP/1.1\r\nProxy-Authorization: \(credential.basicAuthorization)\r\n\r\n"
        #expect(try await RawClient.exchange(port: port, Data(connect.utf8)).hasPrefix("HTTP/1.1 502 "))
    }

    @Test func aMachineListenerTrustsThisProcessWithoutACredential() async throws {
        let server = try await TestServer.start(mode: .echo)
        defer { server.stop() }
        let proxy = RemoteLocalhostProxy()
        defer { proxy.stop() }
        let port = try await proxy.listen(for: "m", route: .init(machineName: "build-box", opener: TCPOpener()))
        #expect(try await proxy.listen(for: "m", route: .init(machineName: "build-box", opener: TCPOpener())) == port)
        // The test process is "this app": no Proxy-Authorization needed.
        let reply = try await RawClient.exchange(port: port, Data("CONNECT localhost:\(server.port) HTTP/1.1\r\n\r\n".utf8),
                                                 then: Data("hello".utf8), until: "hello")
        #expect(reply.hasPrefix("HTTP/1.1 200 Connection Established\r\n\r\n"))
        #expect(reply.hasSuffix("hello"))
        // A page cannot send proxy form; origin form is refused.
        let direct = try await RawClient.exchange(port: port, Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        #expect(direct.hasPrefix("HTTP/1.1 400 "))
    }

    @Test func peerProcessesAreMatchedBySocketOwner() async throws {
        let proxy = RemoteLocalhostProxy()
        defer { proxy.stop() }
        let port = try await proxy.listen(for: "m", route: .init(machineName: "build-box", opener: FailingOpener(.refused)))
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        #expect(await connection.ready(on: DispatchQueue(label: "test.peer")))
        guard case .hostPort(_, let local)? = connection.currentPath?.localEndpoint else {
            Issue.record("no local endpoint")
            return
        }
        #expect(PeerProcess.isTrusted(peerPort: local.rawValue, localPort: port))
        #expect(!PeerProcess.isTrusted(peerPort: local.rawValue, localPort: port, candidates: [1]), "launchd does not own it")
        #expect(!PeerProcess.isTrusted(peerPort: local.rawValue &+ 1, localPort: port))
    }

    @Test func directDestinationsThatResolveToThisMacAreRefused() async throws {
        let server = try await TestServer.start(mode: .echo)
        defer { server.stop() }
        // A public name that resolves to this Mac's loopback (DNS rebinding),
        // without depending on this host's resolver or network.
        let proxy = RemoteLocalhostProxy(directHost: { $0 == "rebound.example" ? .ipv4(.loopback) : NWEndpoint.Host($0) })
        let port = try await proxy.start()
        defer { proxy.stop() }
        let credential = proxy.credential(for: "m", route: .init(machineName: "build-box", opener: TCPOpener()))
        let head = "CONNECT rebound.example:\(server.port) HTTP/1.1\r\nProxy-Authorization: \(credential.basicAuthorization)\r\n\r\n"
        let reply = try await RawClient.exchange(port: port, Data(head.utf8))
        #expect(reply.hasPrefix("HTTP/1.1 403 "), "\(reply)")
        #expect(proxy.stats.refusedLocal == 1)
        #expect(proxy.stats.direct == 0)
        #expect(proxy.stats.tunnels == 0)
    }

    @Test func theUnspecifiedAddressNeverReachesThisMac() async throws {
        let server = try await TestServer.start(mode: .echo)
        defer { server.stop() }
        let proxy = RemoteLocalhostProxy()
        let port = try await proxy.start()
        defer { proxy.stop() }
        let credential = proxy.credential(for: "m", route: .init(machineName: "build-box", opener: TCPOpener()))
        // 0.0.0.0 is not a loopback literal, so it goes direct. The kernel
        // either connects it to this Mac (the guard refuses it) or the host's
        // network refuses it; which one depends on the host. Neither relays.
        let head = "CONNECT 0.0.0.0:\(server.port) HTTP/1.1\r\nProxy-Authorization: \(credential.basicAuthorization)\r\n\r\n"
        let reply = try await RawClient.exchange(port: port, Data(head.utf8))
        #expect(reply.hasPrefix("HTTP/1.1 403 ") || reply.hasPrefix("HTTP/1.1 502 "), "\(reply)")
        #expect(proxy.stats.direct == 0)
        #expect(proxy.stats.tunnels == 0)
    }
}

// MARK: - Helpers

/// A tunnel over a TCP connection to 127.0.0.1 (the daemon's role).
struct TCPOpener: LoopbackTunnelOpening {
    func openTunnel(host: String, port: UInt16) async throws(LoopbackTunnelFailure) -> any LoopbackTunnel {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "test.tunnel")
        guard await connection.ready(on: queue) else { throw .refused }
        return TCPTunnel(connection: connection)
    }
}

final class TCPTunnel: LoopbackTunnel {
    let connection: NWConnection
    let events: AsyncStream<LoopbackTunnelEvent>

    init(connection: NWConnection) {
        self.connection = connection
        let (events, continuation) = AsyncStream.makeStream(of: LoopbackTunnelEvent.self)
        self.events = events
        Task {
            while true {
                guard let (chunk, complete) = try? await connection.receiveChunk(max: 65536) else {
                    continuation.yield(.closed(error: "reset"))
                    break
                }
                if let chunk, !chunk.isEmpty { continuation.yield(.data(chunk)) }
                if complete {
                    continuation.yield(.eof)
                    continuation.yield(.closed(error: nil))
                    break
                }
            }
            continuation.finish()
        }
    }

    func write(_ data: Data) async throws { try await connection.sendAll(data) }
    func consumed(_ count: Int) {}
    func shutdownWrite() { Task { try? await connection.sendFinal() } }
    func close() { connection.cancel() }
}

/// A one-connection-at-a-time TCP server on 127.0.0.1.
final class TestServer: Sendable {
    enum Mode: Sendable {
        case echo
        /// Reads a head, answers with this response, closes.
        case http(String)
    }

    let port: UInt16
    private let listener: NWListener
    private let requests = Mutex<[String]>([])
    private let arrived = Mutex<[CheckedContinuation<String, Never>]>([])

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(mode: Mode) async throws -> TestServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "test.server")
        let port: UInt16 = await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                guard case .ready = state, let port = listener.port?.rawValue,
                      resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: port)
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        let server = TestServer(listener: listener, port: port)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Task { await server.serve(connection, mode: mode) }
        }
        return server
    }

    private func serve(_ connection: NWConnection, mode: Mode) async {
        switch mode {
        case .echo:
            while let (chunk, complete) = try? await connection.receiveChunk(max: 65536) {
                if let chunk { try? await connection.sendAll(chunk) }
                if complete { break }
            }
            connection.cancel()
        case .http(let response):
            var buffer = Data()
            while !buffer.contains(Data("\r\n\r\n".utf8)), let (chunk, complete) = try? await connection.receiveChunk(max: 65536) {
                if let chunk { buffer.append(chunk) }
                if complete { break }
            }
            let request = String(decoding: buffer, as: UTF8.self)
            let waiters = arrived.withLock { waiters in
                defer { waiters.removeAll() }
                return waiters
            }
            requests.withLock { $0.append(request) }
            for waiter in waiters { waiter.resume(returning: request) }
            try? await connection.sendAll(Data(response.utf8))
            try? await connection.sendFinal()
        }
    }

    func firstRequest() async -> String {
        await withCheckedContinuation { continuation in
            let existing = requests.withLock { requests -> String? in
                if let first = requests.first { return first }
                arrived.withLock { $0.append(continuation) }
                return nil
            }
            if let existing { continuation.resume(returning: existing) }
        }
    }

    func stop() { listener.cancel() }
}

/// A raw client of the proxy.
enum RawClient {
    /// Sends `head` (and `then` after the reply head), reads until `until`
    /// appears or the proxy closes, and returns everything read.
    static func exchange(port: UInt16, _ head: Data, then payload: Data? = nil, until marker: String? = nil) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        guard await connection.ready(on: DispatchQueue(label: "test.client")) else { throw URLError(.cannotConnectToHost) }
        try await connection.sendAll(head)
        var received = Data()
        var sentPayload = payload == nil
        while let (chunk, complete) = try? await connection.receiveChunk(max: 65536) {
            if let chunk { received.append(chunk) }
            let text = String(decoding: received, as: UTF8.self)
            if !sentPayload, text.contains("\r\n\r\n"), let payload {
                try await connection.sendAll(payload)
                sentPayload = true
            }
            if let marker, sentPayload, text.hasSuffix(marker) { break }
            if complete { break }
        }
        return String(decoding: received, as: UTF8.self)
    }
}
