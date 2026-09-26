@testable import CmuxMobileSSH
import Darwin
import Foundation
import Network
import Testing

/// SOCKS5 request parsing (RFC 1928), no network.
@Suite struct SSHSocksParseTests {
    @Test func greetingRequiresNoAuthOffer() {
        #expect(SSHSocksParse.greeting([0x05]) == .needMoreData)
        #expect(SSHSocksParse.greeting([0x05, 0x02, 0x00]) == .needMoreData)
        #expect(SSHSocksParse.greeting([0x05, 0x02, 0x02, 0x00]) == .greeting(acceptsNoAuth: true, consumed: 4))
        #expect(SSHSocksParse.greeting([0x05, 0x01, 0x02]) == .greeting(acceptsNoAuth: false, consumed: 3))
        #expect(SSHSocksParse.greeting([0x04, 0x01, 0x00]) == .malformed)
    }

    @Test func connectAddressTypes() {
        // IPv4 127.0.0.1:8080
        #expect(SSHSocksParse.request([5, 1, 0, 1, 127, 0, 0, 1, 0x1F, 0x90]) == .connect(host: "127.0.0.1", port: 8080, consumed: 10))
        // Domain "localhost":3000, resolved by the server.
        let name = Array("localhost".utf8)
        #expect(SSHSocksParse.request([5, 1, 0, 3, UInt8(name.count)] + name + [0x0B, 0xB8])
            == .connect(host: "localhost", port: 3000, consumed: 5 + name.count + 2))
        // IPv6 ::1:443
        let ipv6: [UInt8] = Array(repeating: 0, count: 15) + [1]
        #expect(SSHSocksParse.request([5, 1, 0, 4] + ipv6 + [0x01, 0xBB]) == .connect(host: "0:0:0:0:0:0:0:1", port: 443, consumed: 22))
        // Partial requests wait for more bytes.
        #expect(SSHSocksParse.request([5, 1, 0, 3, 9, 0x6C]) == .needMoreData)
    }

    @Test func unsupportedRequestsAreRejected() {
        // BIND and UDP ASSOCIATE.
        #expect(SSHSocksParse.request([5, 2, 0, 1, 127, 0, 0, 1, 0, 80]) == .reject(.commandNotSupported))
        #expect(SSHSocksParse.request([5, 3, 0, 1, 127, 0, 0, 1, 0, 80]) == .reject(.commandNotSupported))
        #expect(SSHSocksParse.request([5, 1, 0, 9, 0, 0]) == .reject(.addressTypeNotSupported))
        #expect(SSHSocksParse.request([5, 1, 0, 1, 127, 0, 0, 1, 0, 0]) == .reject(.hostUnreachable))
    }
}

/// The SSH SOCKS proxy against the local sshd lab: domain names resolve on
/// the server, several ports share one proxy, and failures produce SOCKS
/// error replies. Run with `CMUX_SSH_LAB=/tmp/cmux-ssh-lab`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] != nil))
struct SSHSocksProxyLabTests {
    let lab = ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] ?? ""

    @Test(.timeLimit(.minutes(1))) func pageAndAPIOnTwoPortsLoadThroughProxyByServerName() async throws {
        let page = try LabWebServer(files: ["index.html": "page-ok"])
        let api = try LabWebServer(files: ["data.json": #"{"api":"ok"}"#])
        defer { page.stop(); api.stop() }
        let connection = try await connect()
        let seen = ConnectLog()
        let proxy = try await SSHSocksProxy.start(over: connection) { host, port in seen.append(host, port) }
        let session = proxiedSession(port: proxy.port)

        // One page load: the document from one port, its API call from another,
        // both by a name only the server resolves (`*.localhost` is loopback
        // there), so both CONNECTs carry the domain name.
        let document = try await get(session, "http://app.localhost:\(page.port)/index.html")
        let data = try await get(session, "http://app.localhost:\(api.port)/data.json")
        #expect(document == "page-ok")
        #expect(data == #"{"api":"ok"}"#)
        #expect(seen.entries.contains { $0 == ("app.localhost", page.port) }, "proxy saw \(seen.entries)")
        #expect(seen.entries.contains { $0 == ("app.localhost", api.port) })

        // Platform fact the browser design depends on: loopback destinations
        // never use the configured proxy, so `localhost` pages need the
        // loopback mirror (MobileSSHComputers+Browser) instead.
        let before = seen.entries.count
        _ = try? await get(session, "http://localhost:\(page.port)/index.html")
        _ = try? await get(session, "http://127.0.0.1:\(page.port)/index.html")
        #expect(seen.entries.count == before, "loopback went through the proxy: \(seen.entries)")

        await proxy.stop()
        await connection.close()
    }

    @Test(.timeLimit(.minutes(1))) func rawConnectRepliesSuccessThenErrors() async throws {
        let server = try LabWebServer(files: ["x.txt": "raw-ok"])
        defer { server.stop() }
        let connection = try await connect()
        let proxy = try await SSHSocksProxy.start(over: connection)
        let port = proxy.port
        let serverPort = server.port

        let ok = try await Task.detached {
            try RawSocks.exchange(proxyPort: port, request: RawSocks.connect(host: "localhost", port: serverPort),
                                  then: "GET /x.txt HTTP/1.0\r\nHost: localhost\r\n\r\n")
        }.value
        #expect(ok.reply.prefix(2) == [0x05, 0x00])
        #expect(ok.rest.hasSuffix("raw-ok"))

        // Nothing listens on port 1: the server refuses, the client gets 0x05.
        let refused = try await Task.detached {
            try RawSocks.exchange(proxyPort: port, request: RawSocks.connect(host: "127.0.0.1", port: 1), then: nil)
        }.value
        #expect(refused.reply.prefix(2) == [0x05, 0x05])

        // BIND is not offered.
        let bind = try await Task.detached {
            try RawSocks.exchange(proxyPort: port, request: [5, 2, 0, 1, 127, 0, 0, 1, 0, 80], then: nil)
        }.value
        #expect(bind.reply.prefix(2) == [0x05, 0x07])

        await proxy.stop()
        await connection.close()
    }

    // MARK: Helpers

    private func connect() async throws -> SSHConnection {
        let key = try SSHParsedPrivateKey(openSSH: try String(contentsOfFile: "\(lab)/client_ed25519", encoding: .utf8)).key
        return try await SSHConnection.connect(
            to: SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()),
            credentials: [.privateKey(key)],
            hostKeyVerifier: RecordingVerifier(accept: true)
        )
    }

    /// The same proxy setting the native browser's data store uses.
    private func proxiedSession(port: Int) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(port)))
        configuration.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
        return URLSession(configuration: configuration)
    }

    private func get(_ session: URLSession, _ url: String) async throws -> String {
        let (data, response) = try await session.data(from: URL(string: url)!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return String(decoding: data, as: UTF8.self)
    }
}

final class ConnectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(String, Int)] = []
    func append(_ host: String, _ port: Int) { lock.withLock { stored.append((host, port)) } }
    var entries: [(String, Int)] { lock.withLock { stored } }
}

/// Blocking SOCKS5 client for exercising replies byte for byte.
enum RawSocks {
    static func connect(host: String, port: Int) -> [UInt8] {
        let name = Array(host.utf8)
        return [5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(port >> 8), UInt8(port & 0xFF)]
    }

    static func exchange(proxyPort: Int, request: [UInt8], then payload: String?) throws -> (reply: [UInt8], rest: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(proxyPort).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        try send(fd, [5, 1, 0])
        let method = try receive(fd, count: 2)
        guard method == [5, 0] else { return (method, "") }
        try send(fd, request)
        let reply = try receive(fd, count: 10)
        guard reply.count == 10, reply[1] == 0, let payload else { return (reply, "") }
        try send(fd, Array(payload.utf8))
        var rest: [UInt8] = []
        while true {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            rest += chunk[0..<n]
        }
        return (reply, String(decoding: rest, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func send(_ fd: Int32, _ bytes: [UInt8]) throws {
        guard write(fd, bytes, bytes.count) == bytes.count else { throw POSIXError(.EIO) }
    }

    private static func receive(_ fd: Int32, count: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        while out.count < count {
            var chunk = [UInt8](repeating: 0, count: count - out.count)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            out += chunk[0..<n]
        }
        return out
    }
}

/// `python3 -m http.server` bound to the lab machine's IPv4 loopback.
final class LabWebServer {
    let port: Int
    private let process = Process()
    private let directory: URL

    init(files: [String: String]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-socks-www-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, body) in files { try Data(body.utf8).write(to: directory.appendingPathComponent(name)) }
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-m", "http.server", "0", "--bind", "127.0.0.1", "--directory", directory.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // "Serving HTTP on 127.0.0.1 port 54321 (http://127.0.0.1:54321/) ..."
        var banner = ""
        while !banner.contains("\n") {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            banner += String(decoding: chunk, as: UTF8.self)
        }
        guard let range = banner.range(of: #"port (\d+)"#, options: .regularExpression),
              let port = Int(banner[range].dropFirst(5)) else {
            process.terminate()
            throw CocoaError(.fileReadCorruptFile)
        }
        self.port = port
    }

    func stop() {
        process.terminate()
        try? FileManager.default.removeItem(at: directory)
    }
}
