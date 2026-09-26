import Darwin
import Foundation
import Testing
@testable import CmuxMobileTunnel

/// SOCKS5 request parsing (RFC 1928), no network.
@Suite struct SocksParseTests {
    @Test func greetingRequiresNoAuthOffer() {
        #expect(SocksParse.greeting([0x05]) == .needMoreData)
        #expect(SocksParse.greeting([0x05, 0x02, 0x00]) == .needMoreData)
        #expect(SocksParse.greeting([0x05, 0x02, 0x02, 0x00]) == .greeting(acceptsNoAuth: true, consumed: 4))
        #expect(SocksParse.greeting([0x05, 0x01, 0x02]) == .greeting(acceptsNoAuth: false, consumed: 3))
        #expect(SocksParse.greeting([0x04, 0x01, 0x00]) == .malformed)
    }

    @Test func connectAddressTypes() {
        #expect(SocksParse.request([5, 1, 0, 1, 127, 0, 0, 1, 0x1F, 0x90]) == .connect(host: "127.0.0.1", port: 8080, consumed: 10))
        let name = Array("localhost".utf8)
        #expect(SocksParse.request([5, 1, 0, 3, UInt8(name.count)] + name + [0x0B, 0xB8])
            == .connect(host: "localhost", port: 3000, consumed: 5 + name.count + 2))
        let ipv6: [UInt8] = Array(repeating: 0, count: 15) + [1]
        #expect(SocksParse.request([5, 1, 0, 4] + ipv6 + [0x01, 0xBB]) == .connect(host: "0:0:0:0:0:0:0:1", port: 443, consumed: 22))
        #expect(SocksParse.request([5, 1, 0, 3, 9, 0x6C]) == .needMoreData)
    }

    @Test func unsupportedRequestsAreRejected() {
        #expect(SocksParse.request([5, 2, 0, 1, 127, 0, 0, 1, 0, 80]) == .reject(.commandNotSupported))
        #expect(SocksParse.request([5, 3, 0, 1, 127, 0, 0, 1, 0, 80]) == .reject(.commandNotSupported))
        #expect(SocksParse.request([5, 1, 0, 9, 0, 0]) == .reject(.addressTypeNotSupported))
        #expect(SocksParse.request([5, 1, 0, 1, 127, 0, 0, 1, 0, 0]) == .reject(.hostUnreachable))
    }
}

/// The phone-side proxy against a fake exit: the SOCKS exchange, the relay,
/// half-close in both directions, and error replies, all byte for byte.
@Suite(.serialized) struct SocksProxyServerTests {
    /// Greets, sends CONNECT, and returns the socket plus the reply bytes.
    private func connect(proxyPort: Int, host: String, port: Int) async throws -> (Int32, [UInt8]) {
        try await Task.detached {
            let fd = try RawClient.connect(port: proxyPort)
            RawClient.send(fd, [5, 1, 0])
            let method = RawClient.receive(fd, count: 2)
            guard method == [5, 0] else { return (fd, method) }
            RawClient.send(fd, RawClient.socksConnect(host: host, port: port))
            return (fd, RawClient.receive(fd, count: 10))
        }.value
    }

    @Test(.timeLimit(.minutes(1))) func relaysBytesAndHalfClosesThroughTheBackend() async throws {
        let backend = ScriptedBackend()
        let seen = Recorder()
        let proxy = try await SocksProxyServer.start(backend: backend) { host, port in seen.append("\(host):\(port)") }
        let (fd, reply) = try await connect(proxyPort: proxy.port, host: "app.localhost", port: 5173)
        defer { close(fd) }
        #expect(reply.prefix(2) == [5, 0])
        #expect(backend.opens.first?.0 == "app.localhost")
        #expect(backend.opens.first?.1 == 5173)
        #expect(seen.values == ["app.localhost:5173"])

        let payload = Array("GET / HTTP/1.0\r\n\r\n".utf8)
        let echoed = try await Task.detached {
            RawClient.send(fd, payload)
            // Half-close: the exit sees end of input, answers, and finishes.
            shutdown(fd, SHUT_WR)
            return RawClient.receiveAll(fd)
        }.value
        #expect(echoed == payload + Array("<eof>".utf8))
        #expect(backend.exits.first?.received == Data(payload))
        await proxy.stop()
    }

    @Test(.timeLimit(.minutes(1))) func bytesSentWithTheRequestAreNotLost() async throws {
        let backend = ScriptedBackend()
        let proxy = try await SocksProxyServer.start(backend: backend)
        let port = proxy.port
        let echoed = try await Task.detached { () throws -> [UInt8] in
            let fd = try RawClient.connect(port: port)
            defer { close(fd) }
            // Greeting, request, and payload in one write (optimistic client).
            RawClient.send(fd, [5, 1, 0] + RawClient.socksConnect(host: "localhost", port: 80) + Array("early".utf8))
            _ = RawClient.receive(fd, count: 2 + 10)
            shutdown(fd, SHUT_WR)
            return RawClient.receiveAll(fd)
        }.value
        #expect(echoed == Array("early<eof>".utf8))
        await proxy.stop()
    }

    @Test(.timeLimit(.minutes(1))) func backendFailuresBecomeSocksReplies() async throws {
        let cases: [(any Error, UInt8)] = [
            (TunnelOpenError.notAllowed, 0x02),
            (TunnelOpenError.connectionRefused, 0x05),
            (TunnelOpenError.hostUnreachable, 0x04),
            (TunnelOpenError.networkUnreachable, 0x03),
            (TunnelOpenError.timedOut, 0x06),
            (TunnelOpenError.unavailable, 0x01),
            (CancellationError(), 0x01),
        ]
        for (error, code) in cases {
            let backend = ScriptedBackend()
            backend.failure = error
            let proxy = try await SocksProxyServer.start(backend: backend)
            let (fd, reply) = try await connect(proxyPort: proxy.port, host: "localhost", port: 3000)
            close(fd)
            #expect(reply.prefix(2) == [5, code], "\(error)")
            await proxy.stop()
        }
    }

    @Test(.timeLimit(.minutes(1))) func unsupportedCommandsNeverReachTheBackend() async throws {
        let backend = ScriptedBackend()
        let proxy = try await SocksProxyServer.start(backend: backend)
        let port = proxy.port
        let reply = try await Task.detached { () throws -> [UInt8] in
            let fd = try RawClient.connect(port: port)
            defer { close(fd) }
            RawClient.send(fd, [5, 1, 0])
            _ = RawClient.receive(fd, count: 2)
            RawClient.send(fd, [5, 2, 0, 1, 127, 0, 0, 1, 0, 80])
            return RawClient.receive(fd, count: 10)
        }.value
        #expect(reply.prefix(2) == [5, 0x07])
        #expect(backend.opens.isEmpty)
        await proxy.stop()
    }

    @Test(.timeLimit(.minutes(1))) func connectionCapRefusesInsteadOfQueueing() async throws {
        let backend = ScriptedBackend()
        let proxy = try await SocksProxyServer.start(backend: backend, maximumConnections: 1)
        let (first, firstReply) = try await connect(proxyPort: proxy.port, host: "localhost", port: 1)
        defer { close(first) }
        #expect(firstReply.prefix(2) == [5, 0])
        let (second, secondReply) = try await connect(proxyPort: proxy.port, host: "localhost", port: 2)
        close(second)
        #expect(secondReply.prefix(2) == [5, 0x01])
        #expect(backend.opens.count == 1)
        await proxy.stop()
    }

    @Test(.timeLimit(.minutes(1))) func stopAbortsOpenTunnels() async throws {
        let backend = ScriptedBackend()
        let proxy = try await SocksProxyServer.start(backend: backend)
        let (fd, reply) = try await connect(proxyPort: proxy.port, host: "localhost", port: 3000)
        defer { close(fd) }
        #expect(reply.prefix(2) == [5, 0])
        await proxy.stop()
        let rest = await Task.detached { RawClient.receiveAll(fd) }.value
        #expect(rest.isEmpty)
        #expect(backend.exits.first?.closed == true)
        #expect(!proxy.isListening)
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
}
