import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextServer

/// The consent write over the app's real person line (``AcpmuxPersonLine``, ``JoinConsentPersonLine``)
/// against a fake acpmux that keeps acpmux's rule (cmux#27216): `_acpmux/machine_consent_set` only on a
/// connection that answered its own `initialize` challenge with `_acpmux/person_prove`. A local Unix
/// connection alone sets nothing.
@MainActor @Suite(.serialized) struct JoinConsentPersonLineTests {
    @Test func theLineProvesThePersonOnTheSameConnectionBeforeItSetsConsent() async throws {
        let socket = Self.socketPath()
        let daemon = try FakeAcpmux(socket: socket, key: AcpmuxPersonKey.spawnKey(for: socket))
        defer { daemon.stop() }
        let line = try #require(await Self.open(socket))
        #expect(line.isPerson && line.supportsConsent)
        #expect(await line.set(.screen, granted: true, ticket: JoinConsentGrantGate().ticket()) == JoinConsentRecord(screen: true, control: false))
        #expect(await line.read() == JoinConsentRecord(screen: true, control: false))
        line.close()
        #expect(daemon.connections == 1, "one connection")
        #expect(daemon.methods == ["initialize", "_acpmux/person_prove", "_acpmux/machine_consent_set", "_acpmux/machine_consent_get"])
        #expect(daemon.granted == ["screen"])
    }

    /// Round 15 P1 over the real line: a grant whose ticket went stale before the line wrote it (the Labs
    /// switch moved or settings loaded) is dropped on the line's own queue, where the bytes would go out:
    /// acpmux never sees the set, the connection closes and the call answers nil.
    @Test func aStaleGrantTicketSendsNothingOverTheRealLine() async throws {
        let socket = Self.socketPath()
        let daemon = try FakeAcpmux(socket: socket, key: AcpmuxPersonKey.spawnKey(for: socket))
        defer { daemon.stop() }
        let line = try #require(await Self.open(socket))
        #expect(line.isPerson)
        let gate = JoinConsentGrantGate()
        let ticket = gate.ticket()
        gate.invalidate()
        #expect(await line.set(.screen, granted: true, ticket: ticket) == nil)
        #expect(await line.read() == nil, "the refused grant closed the connection")
        line.close()
        #expect(daemon.methods == ["initialize", "_acpmux/person_prove"], "the stale grant never reached acpmux")
        #expect(daemon.granted.isEmpty && daemon.refused.isEmpty)
    }

    /// Round 16 P1: a grant still queued on the line when its deadline closes the line. The line's queue is
    /// held across the timeout, so the grant's ticket is still current when the queue gets to it; the model
    /// has its failure, and the person revokes on another connection. Then the queue runs: the timed-out
    /// grant never reaches acpmux, and the revoke stands.
    @Test func aGrantThatTimedOutIsNeverSentEvenAfterALaterRevoke() async throws {
        let socket = Self.socketPath()
        let daemon = try FakeAcpmux(socket: socket, key: AcpmuxPersonKey.spawnKey(for: socket), connections: 2)
        defer { daemon.stop() }
        let environment = try Self.environment(socket)
        let first = try #require(await AcpmuxPersonLine.open(environment, deadline: .seconds(2)))
        #expect(first.isPerson)
        let held = DispatchSemaphore(value: 0)
        // A failed expectation below still lets the queue go (a second signal is never waited on).
        defer { held.signal() }
        first.line.enqueue { held.wait() }
        let gate = JoinConsentGrantGate()
        // Queued behind the held queue; the deadline closes the line and answers nil.
        #expect(await JoinConsentPersonLine(first).set(.screen, granted: true, ticket: gate.ticket()) == nil)
        let second = try #require(await Self.open(socket))
        #expect(await second.set(.screen, granted: false, ticket: nil) == JoinConsentRecord(screen: false, control: false))
        second.close()
        held.signal()
        daemon.waitForConnections()
        #expect(daemon.consent["screen"] == "none", "the timed-out grant never re-granted after the revoke")
        #expect(daemon.sets == ["screen false"], "acpmux saw the revoke alone")
    }

    @Test func aSetWithoutTheProveStepIsRefused() async throws {
        // This app holds no person key for the daemon: no proof exists, so none is sent.
        let socket = Self.socketPath()
        let daemon = try FakeAcpmux(socket: socket, key: AcpmuxPersonKey.newKey())
        defer { daemon.stop() }
        let line = try #require(await Self.open(socket))
        #expect(!line.isPerson)
        #expect(await line.set(.control, granted: true, ticket: JoinConsentGrantGate().ticket()) == nil)
        line.close()
        #expect(daemon.methods == ["initialize", "_acpmux/machine_consent_set"], "no prove step")
        #expect(daemon.refused == ["control"] && daemon.granted.isEmpty)
    }

    @Test func aProofWithAnotherKeyIsRefused() async throws {
        let socket = Self.socketPath()
        _ = AcpmuxPersonKey.spawnKey(for: socket)
        let daemon = try FakeAcpmux(socket: socket, key: AcpmuxPersonKey.newKey())
        defer { daemon.stop() }
        let line = try #require(await Self.open(socket))
        #expect(!line.isPerson)
        #expect(await line.set(.screen, granted: true, ticket: JoinConsentGrantGate().ticket()) == nil)
        line.close()
        #expect(daemon.methods == ["initialize", "_acpmux/person_prove", "_acpmux/machine_consent_set"])
        #expect(daemon.refused == ["screen"] && daemon.granted.isEmpty)
    }

    private static func socketPath() -> String {
        "/tmp/jcl-\(UUID().uuidString.prefix(8))/acpmux.sock"
    }

    /// The app's line to the fake: its peer check passes since the fake runs in this test process.
    private static func open(_ socket: String) async throws -> JoinConsentPersonLine? {
        guard let line = await AcpmuxPersonLine.open(try environment(socket)) else { return nil }
        return JoinConsentPersonLine(line)
    }

    private static func environment(_ socket: String) throws -> AcpmuxEnvironment {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try #require(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0)
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: (socket as NSString).deletingLastPathComponent, isDirectory: true)
        return AcpmuxEnvironment(executable: executable, home: home, socketPath: socket, daemonArguments: [], childEnvironment: [:])
    }

    /// acpmux on a unix socket: `connections` connections (one by default), each served on its own thread
    /// with blocking reads (each bounded), over one consent record. It announces `machine-consent-v1` and a
    /// challenge, takes a proof made with `key` over `acpmux-person-v1 0 unix 0 nonce 0 connection`, and
    /// sets consent only for a proven connection.
    nonisolated final class FakeAcpmux: @unchecked Sendable { // crash-allow: the logs are read and written under `lock`
        private let lock = NSLock()
        private let listener: Int32
        private let directory: String
        private let key: String
        private let expected: Int
        private var log: (methods: [String], granted: [String], refused: [String], sets: [String], connections: Int) = ([], [], [], [], 0)
        private var record = ["screen": "none", "control": "none"]
        private let done = DispatchSemaphore(value: 0)
        private let served = DispatchGroup()

        var methods: [String] { lock.withLock { log.methods } }
        var granted: [String] { lock.withLock { log.granted } }
        var refused: [String] { lock.withLock { log.refused } }
        var connections: Int { lock.withLock { log.connections } }
        /// Each set acpmux took, in order (`surface granted`).
        var sets: [String] { lock.withLock { log.sets } }
        var consent: [String: String] { lock.withLock { record } }

        init(socket: String, key: String, connections: Int = 1) throws {
            self.key = key
            expected = connections
            directory = (socket as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(socket.utf8CString)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in path.withUnsafeBytes { buffer.copyMemory(from: $0) } }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(fd, 4) == 0 else {
                close(fd)
                throw POSIXError(.EADDRINUSE)
            }
            listener = fd
            Thread.detachNewThread { [self] in
                serve()
                done.signal()
            }
        }

        func stop() {
            _ = done.wait(timeout: .now() + 12)
            close(listener)
            try? FileManager.default.removeItem(atPath: directory)
        }

        /// Waits until every connection the test makes has closed (bounded, as each read is).
        func waitForConnections() {
            _ = done.wait(timeout: .now() + 12)
            done.signal()
        }

        /// Accepts the connections the test makes, each served on its own thread; gives up after 10 s
        /// without the next one. Done once every one closed.
        private func serve() {
            for _ in 0..<expected {
                var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&waiting, 1, 10_000) == 1 else { break }
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else { break }
                served.enter()
                Thread.detachNewThread { [self] in
                    serve(fd)
                    served.leave()
                }
            }
            served.wait()
        }

        /// One connection: its own proof, the shared record.
        private func serve(_ fd: Int32) {
            defer { close(fd) }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            // A reply to a client that closed fails, never kills the test process (SIGPIPE).
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { log.connections += 1 }
            var person = false
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(fd, &chunk, chunk.count, 0)
                guard count > 0 else { return }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          let id = request["id"], let method = request["method"] as? String else { continue }
                    let params = request["params"] as? [String: Any] ?? [:]
                    lock.withLock { log.methods.append(method) }
                    var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
                    switch method {
                    case "initialize":
                        let acpmux: [String: Any] = ["capabilities": ["acpmux-v1", "machine-consent-v1"],
                                                     "personChallenge": ["nonce": "n-1", "connection": "c-1"]]
                        reply["result"] = ["_meta": ["acpmux": acpmux]]
                    case "_acpmux/person_prove":
                        person = params["proof"] as? String == Self.proof(key: key, nonce: "n-1", connection: "c-1")
                        reply["result"] = ["person": person]
                    case "_acpmux/machine_consent_set":
                        let surface = params["surface"] as? String ?? ""
                        if person, let granted = params["granted"] as? Bool, consent[surface] != nil {
                            let now = lock.withLock {
                                record[surface] = granted ? "granted" : "none"
                                log.granted.append(surface)
                                log.sets.append("\(surface) \(granted)")
                                return record
                            }
                            reply["result"] = ["consent": now]
                        } else {
                            lock.withLock { log.refused.append(surface) }
                            reply["error"] = ["code": -32001, "message": "permission.person_required"] as [String: Any]
                        }
                    case "_acpmux/machine_consent_get":
                        reply["result"] = ["consent": consent, "lastRefusal": NSNull()] as [String: Any]
                    default:
                        reply["error"] = ["code": -32601, "message": "method not found"] as [String: Any]
                    }
                    guard var frame = try? JSONSerialization.data(withJSONObject: reply) else { return }
                    frame.append(0x0A)
                    _ = frame.withUnsafeBytes { send(fd, $0.baseAddress, frame.count, 0) }
                }
            }
        }

        /// acpmux `hub/person.rs` `person_proof`, written out here rather than calling the app's.
        static func proof(key: String, nonce: String, connection: String) -> String {
            let bytes = Array(key.utf8)
            let keyBytes = stride(from: 0, to: bytes.count, by: 2).compactMap { UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16) }
            let message = Data("acpmux-person-v1\u{0}unix\u{0}\(nonce)\u{0}\(connection)".utf8)
            return HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: keyBytes)).map { String(format: "%02x", $0) }.joined()
        }
    }
}
