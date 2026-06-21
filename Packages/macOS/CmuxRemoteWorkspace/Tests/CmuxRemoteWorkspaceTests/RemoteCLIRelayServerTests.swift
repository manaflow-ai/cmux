import Darwin
import Foundation
import Network
import Testing
@testable import CmuxRemoteWorkspace

/// Test rewriter that records the alias maps it saw and tags the line so the
/// round trip proves the rewrite seam ran.
private final class RecordingRelayRewriter: RemoteRelayCommandRewriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(workspace: [UUID: UUID], surface: [UUID: UUID])] = []

    var calls: [(workspace: [UUID: UUID], surface: [UUID: UUID])] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        lock.lock()
        _calls.append((workspaceAliases, surfaceAliases))
        lock.unlock()
        return Data("rewritten:".utf8) + commandLine
    }
}

/// Minimal one-shot unix socket server standing in for the local cmux
/// control socket: reads the request to EOF, records it, writes `response`.
private final class FakeUnixSocketServer: @unchecked Sendable {
    let path: String
    private let response: Data
    private let lock = NSLock()
    private var _request = Data()
    private let listenFD: Int32

    var request: Data {
        lock.lock()
        defer { lock.unlock() }
        return _request
    }

    init(response: Data) throws {
        self.response = response
        path = NSTemporaryDirectory() + "cmux-relay-test-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "FakeUnixSocketServer", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket() failed errno=\(errno)"])
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        withUnsafeMutableBytes(of: &address) { raw in
            pathBytes.withUnsafeBytes { src in
                raw.baseAddress!.advanced(by: offset).copyMemory(from: src.baseAddress!, byteCount: pathBytes.count)
            }
        }
        let len = socklen_t(MemoryLayout.size(ofValue: address.sun_family) + pathBytes.count)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        guard bound == 0 else {
            let bindErrno = errno  // capture before close() can overwrite errno
            Darwin.close(fd)
            throw NSError(domain: "FakeUnixSocketServer", code: Int(bindErrno), userInfo: [NSLocalizedDescriptionKey: "bind() failed errno=\(bindErrno)"])
        }
        guard listen(fd, 4) == 0 else {
            let listenErrno = errno  // capture before close() can overwrite errno
            Darwin.close(fd)
            throw NSError(domain: "FakeUnixSocketServer", code: Int(listenErrno), userInfo: [NSLocalizedDescriptionKey: "listen() failed errno=\(listenErrno)"])
        }
        self.listenFD = fd
        Thread.detachNewThread { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var scratch = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(client, &scratch, scratch.count)
                if count > 0 {
                    self?.lock.lock()
                    self?._request.append(scratch, count: count)
                    self?.lock.unlock()
                    continue
                }
                break
            }
            self?.response.withUnsafeBytes { raw in
                _ = Darwin.write(client, raw.baseAddress, raw.count)
            }
            Darwin.close(client)
        }
    }

    func close() {
        Darwin.close(listenFD)
        unlink(path)
    }
}

/// Line-oriented TCP client for the relay handshake.
private final class RelayTestClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "relay-test-client")
    private let lock = NSLock()
    private var received = Data()
    private var closed = false

    init(port: Int) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        connection.start(queue: queue)
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.lock.lock()
            if let data { self.received.append(data) }
            if isComplete || error != nil { self.closed = true }
            let done = self.closed
            self.lock.unlock()
            if !done { self.receiveLoop() }
        }
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Waits (bounded) until `predicate(receivedBytes, closed)` holds.
    func wait(timeout: TimeInterval = 5.0, _ predicate: (Data, Bool) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let snapshot = received
            let isClosed = closed
            lock.unlock()
            if predicate(snapshot, isClosed) { return true }
            usleep(20_000)
        }
        return false
    }

    /// Decoded JSON objects, one per received line so far.
    func receivedJSONLines() -> [[String: Any]] {
        lock.lock()
        let snapshot = received
        lock.unlock()
        return snapshot.split(separator: 0x0A).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
    }

    func cancel() { connection.cancel() }
}

@Suite("RemoteCLIRelayServer")
struct RemoteCLIRelayServerTests {
    private let tokenHex = "00112233445566778899aabbccddeeff"

    @Test("an invalid relay token hex is rejected at init (code 7)")
    func invalidTokenRejected() {
        #expect(throws: (any Error).self) {
            _ = try RemoteCLIRelayServer(
                localSocketPath: "/tmp/unused.sock",
                relayID: "relay-1",
                relayTokenHex: "not-hex",
                commandRewriter: RecordingRelayRewriter()
            )
        }
    }

    @Test("happy path: challenge, HMAC auth, rewritten command round trip")
    func authAndForwardRoundTrip() throws {
        let unixServer = try FakeUnixSocketServer(response: Data("{\"ok\":true,\"result\":42}\n".utf8))
        defer { unixServer.close() }
        let rewriter = RecordingRelayRewriter()
        let server = try RemoteCLIRelayServer(
            localSocketPath: unixServer.path,
            relayID: "relay-1",
            relayTokenHex: tokenHex,
            commandRewriter: rewriter
        )
        defer { server.stop() }
        let workspaceAlias = (remote: UUID(), local: UUID())
        server.updateRemoteRelayIDAliases(
            workspaceAliases: [workspaceAlias.remote: workspaceAlias.local],
            surfaceAliases: [:]
        )
        let port = try server.start()
        #expect(try server.start() == port, "start is idempotent and returns the same port")

        let client = RelayTestClient(port: port)
        defer { client.cancel() }

        // Challenge line: wire-pinned protocol/version/relay_id/nonce shape.
        #expect(client.wait { data, _ in data.contains(0x0A) })
        let challenge = try #require(client.receivedJSONLines().first)
        #expect(challenge["protocol"] as? String == "cmux-relay-auth")
        #expect(challenge["version"] as? Int == 1)
        #expect(challenge["relay_id"] as? String == "relay-1")
        let nonce = try #require(challenge["nonce"] as? String)

        // Authenticate with the HMAC the server expects.
        let token = try #require(RemoteCLIRelayServer.Session.hexData(from: tokenHex))
        let message = Data("relay_id=relay-1\nnonce=\(nonce)\nversion=1".utf8)
        let mac = RemoteCLIRelayServer.Session.authMAC(token: token, message: message)
        let auth: [String: Any] = ["relay_id": "relay-1", "mac": mac.map { String(format: "%02x", $0) }.joined()]
        client.send(try JSONSerialization.data(withJSONObject: auth) + Data([0x0A]))

        #expect(client.wait { data, _ in
            String(decoding: data, as: UTF8.self).contains("\"ok\":true")
        })

        // Forward one command; response comes from the fake unix socket.
        client.send(Data("workspace.list {}\n".utf8))
        #expect(client.wait { data, closed in
            String(decoding: data, as: UTF8.self).contains("\"result\":42") && closed
        })
        #expect(String(decoding: unixServer.request, as: UTF8.self) == "rewritten:workspace.list {}\n")
        let call = try #require(rewriter.calls.first)
        #expect(call.workspace == [workspaceAlias.remote: workspaceAlias.local])
        #expect(call.surface.isEmpty)
    }

    @Test("a wrong MAC gets ok:false and the connection closed")
    func wrongMACRejected() throws {
        let unixServer = try FakeUnixSocketServer(response: Data())
        defer { unixServer.close() }
        let server = try RemoteCLIRelayServer(
            localSocketPath: unixServer.path,
            relayID: "relay-1",
            relayTokenHex: tokenHex,
            commandRewriter: RecordingRelayRewriter()
        )
        defer { server.stop() }
        let port = try server.start()

        let client = RelayTestClient(port: port)
        defer { client.cancel() }
        #expect(client.wait { data, _ in data.contains(0x0A) })

        let auth: [String: Any] = ["relay_id": "relay-1", "mac": "deadbeef"]
        client.send(try JSONSerialization.data(withJSONObject: auth) + Data([0x0A]))

        #expect(client.wait { data, closed in
            String(decoding: data, as: UTF8.self).contains("\"ok\":false") && closed
        })
    }
}
