import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Real checked Unix connections and same-connection person proof; no Home fake can allow a tool.
@MainActor @Suite(.serialized) struct HiddenHomeApprovalTests {
    private func fixture(proof: Bool = true) throws -> (AcpmuxApprovalAnswerer, FakeAcpmux) {
        let socket = "/tmp/hha-\(UUID().uuidString.prefix(8))/acpmux.sock"
        let key = proof ? AcpmuxPersonKey.spawnKey(for: socket) : AcpmuxPersonKey.newKey()
        let server = try FakeAcpmux(socket: socket, key: key, connections: 2)
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try #require(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0)
        let env = AcpmuxEnvironment(executable: URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath(),
            home: URL(fileURLWithPath: (socket as NSString).deletingLastPathComponent), socketPath: socket,
            daemonArguments: [], childEnvironment: [:])
        return (AcpmuxApprovalAnswerer(environment: env, chiefHomeID: "abcdef12"), server)
    }

    @Test(arguments: [true, false]) func onceDecisionAnswersActualPendingRequest(_ allow: Bool) async throws {
        let (answerer, server) = try fixture()
        defer { server.stop() }
        let pending = try #require(await answerer.pendingAsk(session: "local/s1", permission: "p1"))
        let entries = try #require(server.info["pending"] as? [[String: Any]])
        let request = try #require(entries.first?["request"])
        let snapshot = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        #expect(AcpmuxApprovalAnswerer.requestDigest(String(decoding: snapshot, as: UTF8.self)) == pending.approval.digest)
        #expect(await answerer.answerOnce(pending.approval, allow: allow, through: { bytes in bytes(); return true }))
        #expect(server.responses == [allow ? "once" : "no"])
        #expect((server.info["pending"] as? [[String: Any]])?.isEmpty == true)
        #expect(server.methods.filter { $0 == "_acpmux/person_prove" }.count == 2)
    }

    @Test func changedSnapshotIsNeverAnswered() async throws {
        let (answerer, server) = try fixture()
        defer { server.stop() }
        let pending = try #require(await answerer.pendingAsk(session: "local/s1", permission: "p1"))
        var info = server.info
        info["pending"] = [["permissionId": "p1", "request": ["toolCall": ["title": "Bash", "rawInput": ["command": "different"]],
            "options": [["optionId": "once", "kind": "allow_once"]]]]]
        server.info = info
        #expect(!(await answerer.answerOnce(pending.approval, allow: true, through: { bytes in bytes(); return true })))
        #expect(server.responses.isEmpty)
    }

    @Test func refusedWriteGateSendsNoDecision() async throws {
        let (answerer, server) = try fixture()
        defer { server.stop() }
        let pending = try #require(await answerer.pendingAsk(session: "local/s1", permission: "p1"))
        #expect(!(await answerer.answerOnce(pending.approval, allow: true, through: { _ in false })))
        #expect(!server.methods.contains("_acpmux/permission_respond"))
        #expect(server.responses.isEmpty)
    }

    @Test func unprovenAppCannotAllowAndFailureKeepsRequestPending() async throws {
        let (answerer, server) = try fixture(proof: false)
        defer { server.stop() }
        let pending = try #require(await answerer.pendingAsk(session: "local/s1", permission: "p1"))
        #expect(!(await answerer.answerOnce(pending.approval, allow: true, through: { bytes in bytes(); return true })))
        #expect(server.responses.isEmpty)
        #expect((server.info["pending"] as? [[String: Any]])?.count == 1)
    }

    @Test func failedDaemonAnswerKeepsPending() async throws {
        let (answerer, server) = try fixture()
        defer { server.stop() }
        let pending = try #require(await answerer.pendingAsk(session: "local/s1", permission: "p1"))
        server.reject = true
        #expect(!(await answerer.answerOnce(pending.approval, allow: false, through: { bytes in bytes(); return true })))
        #expect(server.responses.isEmpty)
        #expect((server.info["pending"] as? [[String: Any]])?.count == 1)
    }

    @Test func ownershipRequiresExactLocalSessionHomeAndOwnerPolicy() {
        let valid: [String: Any] = ["sessionId": "s1", "tags": ["mux.parent": "optchat-chief:abcdef12", "optchat.subagent": "a1"]]
        #expect(AcpmuxPersonLine.isOwnerSubagent(valid, session: "local/s1", home: "abcdef12"))
        #expect(!AcpmuxPersonLine.isOwnerSubagent(valid, session: "peer/s1", home: "abcdef12"))
        #expect(!AcpmuxPersonLine.isOwnerSubagent(valid, session: "local/s2", home: "abcdef12"))
        #expect(!AcpmuxPersonLine.isOwnerSubagent(valid, session: "local/s1", home: "fedcba21"))
        for (key, value) in [("peer", "other"), ("policy", "ask")] {
            var bad = valid; bad[key] = value
            #expect(!AcpmuxPersonLine.isOwnerSubagent(bad, session: "local/s1", home: "abcdef12"))
        }
        for extra in [["optchat.policy": "ask"], ["cmux.chief.role": "turn"], ["optchat.subagent": ""]] {
            var bad = valid; bad["tags"] = ["mux.parent": "optchat-chief:abcdef12", "optchat.subagent": "a1"].merging(extra) { _, new in new }
            #expect(!AcpmuxPersonLine.isOwnerSubagent(bad, session: "local/s1", home: "abcdef12"))
        }
    }
    nonisolated final class FakeAcpmux: @unchecked Sendable { // crash-allow: the logs are read and written under `lock`
        private let lock = NSLock()
        private let listener: Int32
        private let directory: String
        private let key: String
        private let expected: Int
        private var log: (methods: [String], granted: [String], refused: [String], sets: [String], connections: Int) = ([], [], [], [], 0)
        private var infoState: [String: Any] = ["sessionId": "s1", "tags": ["mux.parent": "optchat-chief:abcdef12", "optchat.subagent": "a1"],
            "pending": [["permissionId": "p1", "request": ["toolCall": ["title": "Bash", "rawInput": ["command": "printf '你好 /tmp/a'", "nested": ["n": 1.25]]],
                "options": [["optionId": "once", "kind": "allow_once"], ["optionId": "no", "kind": "reject_once"]]]]]]
        var info: [String: Any] { get { lock.withLock { infoState } } set { lock.withLock { infoState = newValue } } }
        var responses: [String] { lock.withLock { log.sets } }
        private var rejection = false
        var reject: Bool { get { lock.withLock { rejection } } set { lock.withLock { rejection = newValue } } }
        private let done = DispatchSemaphore(value: 0)
        private let served = DispatchGroup()

        var methods: [String] { lock.withLock { log.methods } }
        var granted: [String] { lock.withLock { log.granted } }
        var refused: [String] { lock.withLock { log.refused } }
        var connections: Int { lock.withLock { log.connections } }
        /// Each set acpmux took, in order (`surface granted`).
        var sets: [String] { lock.withLock { log.sets } }

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
                    case "_acpmux/info":
                        reply["result"] = info
                    case "_acpmux/permission_respond":
                        let option = params["optionId"] as? String ?? ""
                        if !reject && (person || option == "no"), params["permissionId"] as? String == "p1",
                           !(info["pending"] as? [[String: Any]] ?? []).isEmpty {
                            lock.withLock { infoState["pending"] = [[String: Any]](); log.sets.append(option) }
                            reply["result"] = [:] as [String: Any]
                        } else {
                            reply["error"] = ["code": -32001, "message": "permission.person_required"] as [String: Any]
                        }
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
