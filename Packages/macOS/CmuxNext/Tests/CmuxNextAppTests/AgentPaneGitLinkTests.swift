import CmuxNextAgentPane
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Darwin
import Foundation
import Testing

/// Where the agent pane's git requests go (p05-ipc-105): on the app's control connection to a
/// daemon with `git-shared-connection-v1`, which runs a connection's git reads apart from its
/// writes; on a read connection and a write connection of the link's own to an older daemon,
/// which answers a connection's git requests in order on its request thread. A fake daemon socket
/// records the connection each git request came on.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct AgentPaneGitLinkTests {
    /// The link's daemon service: a started control connection to the fake socket.
    @MainActor final class FakeGitDaemon: AgentPaneGitDaemon {
        let control: DaemonConnection
        private let socket: FakeGitSocket
        /// What ``supports(_:)`` answers: the socket's, until a test hands the daemon off to a newer build.
        var capabilities: Set<String>

        init(socket: FakeGitSocket) async throws {
            self.socket = socket
            capabilities = socket.capabilities
            let path = socket.path
            let configuration = DaemonConnection.Configuration(clientName: "test-control", treeEvents: .coarse, terminalEnvironment: nil)
            control = DaemonConnection(configuration: configuration, endpointProvider: { DaemonEndpoint(socketPath: path) })
            control.discardEvents()
            _ = try await control.start()
        }

        var isLocal: Bool { true }
        func supports(_ capability: String) -> Bool { capabilities.contains(capability) }
        func controlConnection() async -> DaemonConnection? { control }
        func endpoint() async throws -> DaemonEndpoint { DaemonEndpoint(socketPath: socket.path) }
    }

    static let push = AgentPaneGitWrite.push(sessionId: "chat-1", expectedHead: nil, key: "push-key-1")

    /// The operation the fake echoed in a result.
    static func operation(_ result: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: result) as? [String: Any])?["operation"] as? String
    }

    @Test func aDaemonWithSharedGitSendsReadsAndWritesOnTheControlConnection() async throws {
        let socket = try FakeGitSocket(capabilities: DaemonCapability.required + [AgentPaneGitLink.sharedConnectionCapability])
        defer { socket.stop() }
        let daemon = try await FakeGitDaemon(socket: socket)
        let link = AgentPaneGitLink(daemon: daemon)

        #expect(Self.operation(try await link.read(.status(cwd: "/repo"))) == "git.status")
        #expect(Self.operation(try await link.write(Self.push, in: "/repo")) == "git.push")
        #expect(socket.gitRequests == [.init(connection: 1, operation: "git.status"), .init(connection: 1, operation: "git.push")])
        #expect(socket.opened == 1, "no connection beside the control connection")

        link.close()
        #expect(Self.operation(try await link.read(.status(cwd: "/repo"))) == "git.status",
                "closing the link leaves the service's control connection open")
        #expect(socket.openNow == 1)
        await daemon.control.close()
    }

    @Test func anOlderDaemonGetsAReadAndAWriteConnectionOfTheLinksOwn() async throws {
        let socket = try FakeGitSocket(capabilities: DaemonCapability.required)
        defer { socket.stop() }
        let daemon = try await FakeGitDaemon(socket: socket)
        let link = AgentPaneGitLink(daemon: daemon)

        #expect(Self.operation(try await link.read(.status(cwd: "/repo"))) == "git.status")
        #expect(Self.operation(try await link.write(Self.push, in: "/repo")) == "git.push")
        #expect(Self.operation(try await link.read(.status(cwd: "/repo"))) == "git.status")
        #expect(socket.gitRequests == [.init(connection: 2, operation: "git.status"), .init(connection: 3, operation: "git.push"),
                                       .init(connection: 2, operation: "git.status")])
        #expect(socket.opened == 3, "the control connection, then one for reads and one for writes")

        link.close()
        await socket.waitUntil(open: 1)
        #expect(socket.openNow == 1, "the link's own connections close; the control connection stays")
        await daemon.control.close()
    }

    @Test func aStoppedDaemonFailsTheReadNotConnected() async throws {
        let socket = try FakeGitSocket(capabilities: DaemonCapability.required + [AgentPaneGitLink.sharedConnectionCapability])
        defer { socket.stop() }
        let daemon = try await FakeGitDaemon(socket: socket)
        await daemon.control.close()
        let link = AgentPaneGitLink(daemon: daemon)

        await #expect(throws: AgentPaneGitFailure.notConnected) { try await link.read(.status(cwd: "/repo")) }
        #expect(socket.gitRequests.isEmpty)
    }

    /// A git reply (a diff can be 8 MiB) decodes off the control connection's actor: terminal input
    /// sent while it decodes is answered. The decode holds until the input's answer, at most 10 s.
    @Test func aControlRequestIsAnsweredWhileAGitReplyDecodes() async throws {
        let socket = try FakeGitSocket(capabilities: DaemonCapability.required + [AgentPaneGitLink.sharedConnectionCapability])
        defer { socket.stop() }
        let daemon = try await FakeGitDaemon(socket: socket)
        let client = GitResourceClient(connection: daemon.control)
        let diff = Task {
            try await client.request("git.diff", params: ["path": .string("/repo")], idempotencyKey: nil,
                                     timeout: GitResourceClient.timeout, as: SlowGitResult.self)
        }
        for await _ in SlowGitResult.gate.decoding { break }

        let input = try await daemon.control.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "terminal.input.write", params: [:], idempotencyKey: nil)
        }, as: JSONValue.self)
        SlowGitResult.gate.release.signal()

        #expect(input == .object(["operation": .string("terminal.input.write")]))
        #expect(try await diff.value.releasedInTime, "the terminal input waited behind the diff's decode")
        await daemon.control.close()
    }

    /// A quiet handoff of the control connection does not wait for a git push in flight (up to two
    /// minutes), and a git read sent while the handoff holds the connection waits until it ends.
    @Test func aQuietHandoffSkipsAGitPushInFlightAndHoldsANewGitRead() async throws {
        let socket = try FakeGitSocket(capabilities: DaemonCapability.required + [AgentPaneGitLink.sharedConnectionCapability],
                                       holding: ["git.push"])
        defer { socket.stop() }
        let daemon = try await FakeGitDaemon(socket: socket)
        let link = AgentPaneGitLink(daemon: daemon)
        let push = Task { try await link.write(Self.push, in: "/repo") }
        await socket.waitUntil(gitRequests: 1)

        #expect(await daemon.control.quietHandoff { true }, "the handoff ran with the push unanswered")
        let read = Task { try await link.read(.status(cwd: "/repo")) }
        while await daemon.control.heldRequests == 0 { await Task.yield() }
        #expect(await daemon.control.heldRequests == 1, "the accepted handoff holds the read")
        #expect(socket.gitRequests == [.init(connection: 1, operation: "git.push")], "the held read was not sent")

        await daemon.control.releaseHandoffHold()
        #expect(Self.operation(try await read.value) == "git.status")
        socket.answerHeld()
        #expect(Self.operation(try await push.value) == "git.push")
        #expect(socket.gitRequests == [.init(connection: 1, operation: "git.push"), .init(connection: 1, operation: "git.status")])
        await daemon.control.close()
    }

    /// A daemon that gains `git-shared-connection-v1` (handed off to a newer build): the link closes
    /// its own read and write connections and sends the next read on the control connection.
    @Test func aDaemonThatGainsSharedGitClosesTheLinksOwnConnections() async throws {
        let socket = try FakeGitSocket(capabilities: DaemonCapability.required)
        defer { socket.stop() }
        let daemon = try await FakeGitDaemon(socket: socket)
        let link = AgentPaneGitLink(daemon: daemon)
        #expect(Self.operation(try await link.read(.status(cwd: "/repo"))) == "git.status")
        #expect(Self.operation(try await link.write(Self.push, in: "/repo")) == "git.push")
        #expect(socket.openNow == 3, "the control connection, then one for reads and one for writes")

        daemon.capabilities.insert(AgentPaneGitLink.sharedConnectionCapability)
        #expect(Self.operation(try await link.read(.status(cwd: "/repo"))) == "git.status")
        await socket.waitUntil(open: 1)
        #expect(socket.openNow == 1, "the link's own connections closed; the control connection stays")
        #expect(socket.opened == 3, "no connection opened after the switch")
        #expect(socket.gitRequests.last == .init(connection: 1, operation: "git.status"), "the read went on the control connection")
        await daemon.control.close()
    }
}

extension DaemonConnection {
    /// The requests a quiet handoff holds now; nil when none runs.
    var heldRequests: Int? { handoffHold?.count }
}

/// A git result whose decode waits for ``gate``'s release (at most 10 s): a large reply's decode.
nonisolated struct SlowGitResult: Decodable, Sendable {
    nonisolated final class Gate: Sendable {
        let decoding: AsyncStream<Void>
        let started: AsyncStream<Void>.Continuation
        let release = DispatchSemaphore(value: 0)

        init() {
            (decoding, started) = AsyncStream<Void>.makeStream()
        }
    }

    static let gate = Gate()
    /// Whether the release came before the 10 s limit.
    let releasedInTime: Bool

    init(from decoder: any Decoder) throws {
        Self.gate.started.yield()
        releasedInTime = Self.gate.release.wait(timeout: .now() + 10) == .success
    }
}

/// A Unix socket served by this test process that speaks just enough of the daemon's protocol for
/// a control connection's handshake (`identify` with `capabilities`; every other command `ok`) and
/// answers each `cmux.protocol/2` request with `{operation}`, recording the accepted connection
/// (counted from 1) it came on. The answers to the `holding` operations wait for ``answerHeld()``.
nonisolated final class FakeGitSocket: Sendable {
    struct GitRequest: Equatable, Sendable {
        let connection: Int
        let operation: String
    }

    let path: String
    let capabilities: Set<String>
    private let capabilityList: [String]
    private let holding: Set<String>
    private let listener: Int32
    private let state = Mutex(State())
    /// One line at a time on a client: a held answer goes out from the test beside the serving thread's.
    private let sending = Mutex(())

    nonisolated private struct State {
        var clients: Set<Int32> = []
        var opened = 0
        var gitRequests: [GitRequest] = []
        var held: [(client: Int32, id: String, operation: String)] = []
        var waits: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var gitWaits: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    init(capabilities: [String], holding: Set<String> = []) throws {
        self.capabilities = Set(capabilities)
        capabilityList = capabilities
        self.holding = holding
        path = "/tmp/cng-\(UUID().uuidString.prefix(8).lowercased()).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        self.listener = listener
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 8) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        let thread = Thread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                let index = state.withLock { state -> Int in
                    state.clients.insert(client)
                    state.opened += 1
                    return state.opened
                }
                let serving = Thread { [self] in serve(client, index: index) }
                serving.qualityOfService = .utility
                serving.start()
            }
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Connections accepted so far.
    var opened: Int { state.withLock { $0.opened } }
    /// Connections open now.
    var openNow: Int { state.withLock { $0.clients.count } }
    /// The git requests answered, in order.
    var gitRequests: [GitRequest] { state.withLock { $0.gitRequests } }

    /// Returns once exactly `open` connections are open.
    func waitUntil(open target: Int) async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                guard state.clients.count != target else { return true }
                state.waits.append((target, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Returns once `count` git requests have come in.
    func waitUntil(gitRequests count: Int) async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                guard state.gitRequests.count < count else { return true }
                state.gitWaits.append((count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Answers the held requests.
    func answerHeld() {
        let held = state.withLock { state -> [(client: Int32, id: String, operation: String)] in
            defer { state.held.removeAll() }
            return state.held
        }
        for request in held {
            _ = send(["protocol": "cmux.protocol/2", "type": "response", "id": request.id, "ok": true,
                      "result": ["operation": request.operation]], to: request.client)
        }
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }

    private func serve(_ client: Int32, index: Int) {
        defer { ended(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                guard answer(request, to: client, index: index) else { return }
            }
        }
    }

    /// The connection ended: it is no longer open, and the waits it satisfies return.
    private func ended(_ client: Int32) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.clients.remove(client)
            let open = state.clients.count
            let ready = state.waits.filter { $0.count == open }.map(\.continuation)
            state.waits.removeAll { $0.count == open }
            return ready
        }
        close(client)
        for continuation in ready { continuation.resume() }
    }

    private func answer(_ request: [String: Any], to client: Int32, index: Int) -> Bool {
        if request["protocol"] as? String == "cmux.protocol/2", let id = request["id"] as? String {
            let operation = request["operation"] as? String ?? ""
            let hold = holding.contains(operation)
            if operation.hasPrefix("git.") {
                let arrived = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                    state.gitRequests.append(GitRequest(connection: index, operation: operation))
                    if hold { state.held.append((client, id, operation)) }
                    let count = state.gitRequests.count
                    let arrived = state.gitWaits.filter { $0.count <= count }.map(\.continuation)
                    state.gitWaits.removeAll { $0.count <= count }
                    return arrived
                }
                for continuation in arrived { continuation.resume() }
            }
            if hold { return true }
            return send(["protocol": "cmux.protocol/2", "type": "response", "id": id, "ok": true,
                         "result": ["operation": operation]], to: client)
        }
        guard let id = request["id"] as? Int, let command = request["cmd"] as? String else { return true }
        switch command {
        case "identify":
            let identity: [String: Any] = ["app": "cmux-tui", "version": "test", "protocol": 12, "generation": "gen-git",
                                           "session": "cng", "pid": 1, "capabilities": capabilityList]
            return send(["id": id, "ok": true, "data": identity], to: client)
        default:
            return send(["id": id, "ok": true, "data": [String: Any]()], to: client)
        }
    }

    /// Writes `object` and its newline whole.
    private func send(_ object: [String: Any], to client: Int32) -> Bool {
        guard var bytes = try? JSONSerialization.data(withJSONObject: object) else { return false }
        bytes.append(0x0A)
        return sending.withLock { _ in Self.write(bytes, to: client) }
    }

    private static func write(_ bytes: Data, to client: Int32) -> Bool {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(client, base + offset, raw.count - offset, 0)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
