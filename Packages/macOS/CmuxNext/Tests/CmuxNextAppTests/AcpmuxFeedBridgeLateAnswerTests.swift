@testable import CmuxNextApp
@testable import CmuxNextAgentPane
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// The real feed bridge against an acpmux whose one pending peer session answers its
/// `_acpmux/info` only after the recovery's read deadline, with a second recovery (a second
/// watch reply) asked while that read is still out. No reconnect and no `permission_pending`
/// notification come: the prompt reaches the feed only through the late answer. It must be
/// posted once, when the answer comes, from one info read on the wire.
@MainActor @Suite(.serialized) struct AcpmuxFeedBridgeLateAnswerTests {
    @Test func aLateInfoAnswerIsPostedOnceFromOneRead() async throws {
        let socket = "/tmp/afla-\(UUID().uuidString.prefix(8))/acpmux.sock"
        let daemon = try LateAcpmux(socket: socket)
        defer { daemon.stop() }
        let clock = ManualClock()
        let deadline = Duration.seconds(10)
        let posts = Posts()
        var bridge: AcpmuxPermissionFeedBridge? = AcpmuxPermissionFeedBridge(
            environment: try Self.environment(socket),
            owner: { _, body in
                posts.add(op: body["op"] as? String, permission: body["idempotency_key"] as? String,
                          afterAnswer: daemon.answered)
                return ["value": ["item": ["id": "item-\(posts.all.count)"]]]
            },
            isSignedIn: { true }, ownInstall: { "inst_mac" },
            presenceKeys: { throw CancellationError() },
            pendingReads: AcpmuxPendingReads(width: 4, deadline: deadline, clock: clock))
        defer { bridge = nil }
        bridge?.start()

        // The first recovery (the watch reply) asks the session's info; the peer holds it.
        try await daemon.arrivals.wait(for: "_acpmux/info", count: 1, within: .seconds(10))
        try await clock.waitForSleeper()
        clock.advance(by: deadline)

        // A second recovery while that read is still out.
        daemon.sendWatchReply()
        try await daemon.arrivals.wait(for: "_acpmux/sessions", count: 2, within: .seconds(10))
        try await clock.waitForSleeper()
        clock.advance(by: deadline)
        #expect(posts.all.isEmpty, "nothing is posted before the answer")

        daemon.answerInfo()
        await posts.first(within: .seconds(5))
        let infoReads = daemon.infoAsked
        let connections = daemon.connections
        let closed = daemon.closed
        bridge = nil

        #expect(posts.all.count == 1, "posts: \(posts.all)")
        #expect(posts.all.first?.op == "feed.post")
        #expect(posts.all.first?.permission == "acpmux:perm-late")
        let allAfterAnswer = posts.all.allSatisfy(\.afterAnswer)
        #expect(allAfterAnswer, "a post was sent before the late answer came")
        #expect(infoReads.count == 1, "info reads on the wire: \(infoReads)")
        #expect(connections == 1 && closed == 0, "the connection ended or the bridge reconnected")
    }

    /// One feed call the bridge made.
    struct Post {
        let op: String?
        let permission: String?
        let afterAnswer: Bool
        /// A post's `thread` (`acpmux:<session key>`); nil for another op.
        var thread: String?
    }

    /// The bridge's feed calls, and a bounded wait for the first.
    @MainActor final class Posts {
        private(set) var all: [Post] = []
        private var waiter: CheckedContinuation<Void, Never>?

        func add(op: String?, permission: String?, afterAnswer: Bool, thread: String? = nil) {
            all.append(Post(op: op, permission: permission, afterAnswer: afterAnswer, thread: thread))
            waiter?.resume()
            waiter = nil
        }

        /// Returns once a call is made, or after `limit` on the wall clock.
        func first(within limit: Duration) async {
            await count(1, within: limit)
        }

        /// Returns once `count` calls are made, or after `limit` on the wall clock.
        func count(_ count: Int, within limit: Duration) async {
            while all.count < count, await next(within: limit) {}
        }

        /// Returns true once another call is made, false after `limit` on the wall clock.
        private func next(within limit: Duration) async -> Bool {
            let before = all.count
            let timer = Task { @MainActor in
                // A cancelled timer (its wait already ended) must not end the next wait.
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                self.waiter?.resume()
                self.waiter = nil
            }
            await withCheckedContinuation { waiter = $0 }
            timer.cancel()
            return all.count > before
        }
    }

    /// The methods the fake acpmux was asked, and a bounded wait for one of them.
    @MainActor final class Arrivals {
        struct TimedOut: Error, CustomStringConvertible {
            let method: String
            let count: Int
            var description: String { "acpmux was not asked \(method) \(count) time(s)" }
        }

        private var counts: [String: Int] = [:]
        private var waiter: (method: String, count: Int, continuation: CheckedContinuation<Bool, Never>)?

        func record(_ method: String) {
            counts[method, default: 0] += 1
            if let waiter, counts[waiter.method, default: 0] >= waiter.count {
                self.waiter = nil
                waiter.continuation.resume(returning: true)
            }
        }

        /// Returns once `method` was asked `count` times; throws after `limit` on the wall clock.
        func wait(for method: String, count: Int, within limit: Duration) async throws {
            guard counts[method, default: 0] < count else { return }
            let timer = Task { @MainActor in
                // A cancelled timer (its wait already ended) must not end the next wait.
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                let waiting = self.waiter
                self.waiter = nil
                waiting?.continuation.resume(returning: false)
            }
            let arrived = await withCheckedContinuation { waiter = (method, count, $0) }
            timer.cancel()
            if !arrived { throw TimedOut(method: method, count: count) }
        }
    }

    /// The test process is the server peer the bridge's line checks for: the fake runs in it.
    static func environment(_ socket: String) throws -> AcpmuxEnvironment {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try #require(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0)
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: (socket as NSString).deletingLastPathComponent, isDirectory: true)
        return AcpmuxEnvironment(executable: executable, home: home, socketPath: socket, daemonArguments: [], childEnvironment: [:])
    }

    /// acpmux on a unix socket. It answers `initialize` (with `pendingOnly` served), the watch and
    /// `_acpmux/sessions` (one peer session with a pending prompt), and holds every
    /// `_acpmux/info` until ``answerInfo()``. It never sends a notification.
    nonisolated final class LateAcpmux: @unchecked Sendable { // crash-allow: mutable fields are read and written under `lock`
        let arrivals: Arrivals
        private let listener: Int32
        private let directory: String
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var client: Int32 = -1
        private var heldInfo: [Any] = []
        private var asked: [String] = []
        private var accepted = 0
        private var closes = 0
        private var isAnswered = false
        private var stopped = false

        /// The session ids of the `_acpmux/info` requests that reached it.
        var infoAsked: [String] { lock.withLock { asked } }
        /// Connections accepted.
        var connections: Int { lock.withLock { accepted } }
        /// Connections that ended.
        var closed: Int { lock.withLock { closes } }
        /// Whether ``answerInfo()`` has sent the info answers.
        var answered: Bool { lock.withLock { isAnswered } }

        @MainActor
        init(socket: String) throws {
            arrivals = Arrivals()
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

        /// Another reply to the watch (id 3), as a second recovery's trigger.
        func sendWatchReply() {
            reply(["jsonrpc": "2.0", "id": 3, "result": ["sessions": [Any]()]])
        }

        /// The prompt request the peer session holds.
        static var request: [String: Any] {
            [
                "sessionId": "acp_peer_late",
                "toolCall": ["toolCallId": "call-1", "title": "Run make", "kind": "execute", "rawInput": ["command": "make"]],
                "options": [["optionId": "allow", "kind": "allow_once", "name": "Allow"]],
            ]
        }

        /// Answers every held `_acpmux/info` with `pending` (default: the session's one prompt).
        func answerInfo(pending: [[String: Any]] = [["permissionId": "perm-late", "request": LateAcpmux.request]]) {
            let ids: [Any] = lock.withLock {
                isAnswered = true
                defer { heldInfo = [] }
                return heldInfo
            }
            for id in ids {
                reply(["jsonrpc": "2.0", "id": id, "result": ["pending": pending]])
            }
        }

        /// Sends the bridge a notification, as acpmux sends a watcher one.
        func notify(_ method: String, _ params: [String: Any]) {
            reply(["jsonrpc": "2.0", "method": method, "params": params])
        }

        func stop() {
            let fd: Int32 = lock.withLock {
                stopped = true
                return client
            }
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
            _ = done.wait(timeout: .now() + 15)
            close(listener)
            try? FileManager.default.removeItem(atPath: directory)
        }

        private func reply(_ message: [String: Any]) {
            guard var frame = try? JSONSerialization.data(withJSONObject: message) else { return }
            frame.append(0x0A)
            lock.withLock {
                guard client >= 0 else { return }
                _ = frame.withUnsafeBytes { send(client, $0.baseAddress, frame.count, 0) }
            }
        }

        private func serve() {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while !lock.withLock({ stopped }) {
                let fd = lock.withLock { client }
                var waiting = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
                guard poll(&waiting, fd >= 0 ? 2 : 1, 30_000) > 0 else { return }
                if waiting[0].revents & Int16(POLLIN) != 0 {
                    let accepted = accept(listener, nil, nil)
                    guard accepted >= 0 else { return }
                    var noSignal: Int32 = 1
                    setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                    let first: Bool = lock.withLock {
                        self.accepted += 1
                        guard client < 0 else { return false }
                        client = accepted
                        return true
                    }
                    // Only the first connection is served; a reconnect is counted and closed.
                    if !first { close(accepted) }
                    continue
                }
                guard fd >= 0, waiting[1].revents != 0 else { continue }
                let count = recv(fd, &chunk, chunk.count, 0)
                guard count > 0 else {
                    lock.withLock {
                        client = -1
                        closes += 1
                    }
                    close(fd)
                    return
                }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          let id = request["id"], let method = request["method"] as? String else { continue }
                    handle(id: id, method: method, params: request["params"] as? [String: Any] ?? [:])
                }
            }
        }

        private func handle(id: Any, method: String, params: [String: Any]) {
            let arrivals = arrivals
            switch method {
            case "initialize":
                reply(["jsonrpc": "2.0", "id": id, "result": [
                    "_meta": ["acpmux": ["capabilities": ["acpmux-v1", AcpmuxSessionListGate.pendingCapability]]],
                ]])
            case "_acpmux/watch":
                sendWatchReply()
            case "_acpmux/sessions":
                reply(["jsonrpc": "2.0", "id": id, "result": [
                    "sessions": [["sessionId": "acp_peer_late", "qualifiedSessionId": "peer-a/acp_peer_late", "peer": "peer-a",
                                  "pendingPermissions": 1]],
                ]])
            case "_acpmux/info":
                lock.withLock {
                    asked.append(params["sessionId"] as? String ?? "")
                    heldInfo.append(id)
                }
            default:
                break
            }
            Task { @MainActor in arrivals.record(method) }
        }
    }
}
