import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// After an update, this app's acpmux of another build is handed off to the bundled one at a
/// quiet moment: no session runs a turn or waits on a permission. With agent hosts its agents
/// keep running; without them its chats resume from disk at their next prompt. A busy daemon
/// keeps running until a session change makes it quiet, and that wait does not use up the
/// build's one handoff.
struct AcpmuxQuietHandoffDecisionTests {
    typealias Handoff = AcpmuxVersionHandoff

    @Test func withTheToggleOffNothingChanges() {
        #expect(Handoff.decide("old", "new", true) == .restart)
        #expect(Handoff.decide("old", "new", false) == .keep("its agents would end: no agent hosts"))
    }

    @Test func withTheToggleOnEveryStaleDaemonWaitsForQuiet() {
        #expect(Handoff.decide("old", "new", true, whenQuiet: true) == .restartWhenQuiet)
        #expect(Handoff.decide("old", "new", false, whenQuiet: true) == .restartWhenQuiet)
        for hosts in [true, false] {
            #expect(Handoff.decide("old", "new", hosts, whenQuiet: true, quiet: true) == .restart)
            #expect(Handoff.decide("old", "new", hosts, whenQuiet: true, quiet: false) != .restart)
        }
    }

    @Test func agentHostsWaitNoLongerThanTheCapNorForAReplacedBundle() {
        #expect(Handoff.decide("old", "new", true, whenQuiet: true, quiet: false, overdue: true) == .restart)
        #expect(Handoff.decide("a", "a", true, replaced: true, whenQuiet: true, quiet: false) == .restart)
        // Without agent hosts a busy daemon would lose its turns: it waits.
        #expect(Handoff.decide("old", "new", false, whenQuiet: true, quiet: false, overdue: true) != .restart)
        #expect(Handoff.decide("a", "a", false, replaced: true, whenQuiet: true, quiet: false) != .restart)
        #expect(Handoff.decide("a", "a", false, replaced: true, whenQuiet: true, quiet: true) == .restart)
    }

    @Test func theSameBuildIsNeverReplaced() {
        #expect(Handoff.decide("a", "a", true, whenQuiet: true, quiet: true) == .keep("same build"))
        #expect(Handoff.decide(nil, "a", false, whenQuiet: true, quiet: true) == .keep("running build unknown"))
    }

    @Test func quietMeansNoTurnNoPermissionNoMove() {
        func quiet(_ sessions: [[String: Any]]) -> Bool { AcpmuxQuietHandoff.quiet(sessions: sessions) }
        let idle: [String: Any] = ["sessionId": "a", "status": "idle", "turn": NSNull(), "pendingPermissions": 0]
        #expect(quiet([]))
        #expect(quiet([idle, ["sessionId": "b", "status": "disconnected"]]))
        #expect(!quiet([idle, ["status": "idle", "turn": ["prompt": "p", "startedAt": 5]]]))
        #expect(!quiet([["status": "running"]]))
        #expect(!quiet([["status": "waiting"]]))
        #expect(!quiet([["status": "idle", "pendingPermissions": 1]]))
        #expect(!quiet([["status": "idle", "moving": true]]))
        // A peer's session runs on that peer.
        #expect(quiet([["status": "running", "turn": ["prompt": "p"], "peer": "mini"]]))
        // A reply this build cannot read is not quiet.
        #expect(!AcpmuxQuietHandoff.quiet(sessions: nil))
        #expect(!AcpmuxQuietHandoff.quiet(sessions: "sessions"))
    }

    @Test func aTurnEndOrAnAnsweredPermissionEndsTheWait() throws {
        func line(_ params: [String: Any], method: String = "_acpmux/session_changed") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method, "params": params] as [String: Any])
        }
        #expect(AcpmuxQuietHandoff.endsBusy(try line(["sessionId": "s", "kind": "turn_end"])))
        #expect(AcpmuxQuietHandoff.endsBusy(try line(["sessionId": "s", "kind": "permission_decision"])))
        #expect(!AcpmuxQuietHandoff.endsBusy(try line(["sessionId": "s", "kind": "titled"])))
        #expect(!AcpmuxQuietHandoff.endsBusy(try line(["sessionId": "s", "kind": "turn_end", "peer": "mini"])))
        #expect(!AcpmuxQuietHandoff.endsBusy(try line(["kind": "turn_end"], method: "_acpmux/permission_pending")))
    }

    @Test func aBusyDaemonWithAgentHostsIsOverdueAfterTheCap() {
        let clock = AcpmuxWatchClock()
        let wait = AcpmuxQuietHandoff(clock: clock, cap: .seconds(600))
        #expect(!wait.overdue(home: "/h", pid: 7))
        wait.deferred(home: "/h", pid: 7)
        clock.advance(.seconds(599))
        wait.deferred(home: "/h", pid: 7)
        #expect(!wait.overdue(home: "/h", pid: 7))
        clock.advance(.seconds(1))
        #expect(wait.overdue(home: "/h", pid: 7))
        #expect(!wait.overdue(home: "/h", pid: 8))
    }

    @Test func aMemoryStoreIsReadFromStatus() {
        #expect(AcpmuxStatus(["store": ["mode": "memory"]]).memoryStore)
        #expect(!AcpmuxStatus(["store": ["mode": "local"]]).memoryStore)
        #expect(!AcpmuxStatus([:]).memoryStore)
    }
}

/// The handoff end to end against a stand-in old daemon (this test process, never this app's
/// acpmux) whose pid is a `sleep` child it ends at `_acpmux/shutdown`, then answers as the
/// daemon the app started (the bundled stand-in only prints its ready line).
@Suite(.serialized, .timeLimit(.minutes(2)))
struct AcpmuxQuietHandoffTests {
    @Test func aBusyDaemonWithoutAgentHostsIsKeptAndReplacedOnceQuiet() async throws {
        let fixture = try QuietFixture(agentHosts: false)
        defer { fixture.remove() }
        let wait = AcpmuxQuietHandoff(clock: AcpmuxWatchClock())
        let status = try await AcpmuxStatusClient.status(socketPath: fixture.environment.socketPath)

        fixture.daemon.busy.withLock { $0 = true }
        let whileBusy = await AcpmuxVersionHandoff.handOffIfStale(status, environment: fixture.environment, quietWait: wait)
        #expect(whileBusy == .waitingForQuiet)
        // The toggle off: a daemon without agent hosts is kept, as before.
        fixture.daemon.busy.withLock { $0 = false }
        let toggleOff = await AcpmuxVersionHandoff.handOffIfStale(status, environment: fixture.environment)
        #expect(toggleOff == .kept)
        #expect(!fixture.daemon.shutDown.withLock { $0 })
        // Quiet: the wait did not use up the build's handoff.
        let whenQuiet = await AcpmuxVersionHandoff.handOffIfStale(status, environment: fixture.environment, quietWait: wait)
        #expect(whenQuiet == .stopped)
        #expect(fixture.daemon.shutDown.withLock { $0 })
        #expect(await fixture.eventually { !agentPaneProcessIsRunning(fixture.oldPid) })
    }

    /// A stale daemon with agent hosts and a running turn: the app keeps it, watches its
    /// sessions, and at the turn's end hands it off and starts the bundled daemon.
    @Test func aBusyDaemonWithAgentHostsIsHandedOffAtTheTurnsEnd() async throws {
        let fixture = try QuietFixture(agentHosts: true)
        defer { fixture.remove() }
        fixture.daemon.busy.withLock { $0 = true }
        let host = fixture.host()

        _ = try? await host.prewarm()
        #expect(!fixture.daemon.shutDown.withLock { $0 }, "a busy daemon was handed off mid-turn")
        #expect(fixture.launches == 0)
        #expect(await fixture.eventually { fixture.daemon.watchers.withLock { !$0.isEmpty } }, "the app does not watch the busy daemon")

        fixture.daemon.busy.withLock { $0 = false }
        fixture.daemon.notify(kind: "turn_end")
        #expect(await fixture.eventually { fixture.launches == 1 }, "the turn's end did not hand the daemon off")
        #expect(fixture.daemon.shutDown.withLock { $0 })
        #expect(await fixture.eventually { !agentPaneProcessIsRunning(fixture.oldPid) })
    }

    /// A stale daemon with agent hosts whose turn sends no event that ends the wait (it only
    /// streams output) and gets no reconnect: the cap's deadline hands it off.
    @Test func aBusyDaemonWithAgentHostsIsHandedOffAtTheCapWithNoEvent() async throws {
        let fixture = try QuietFixture(agentHosts: true)
        defer { fixture.remove() }
        fixture.daemon.busy.withLock { $0 = true }
        let clock = AcpmuxWatchClock()
        let host = fixture.host(quietClock: clock)

        _ = try? await host.prewarm()
        #expect(await fixture.eventually { fixture.daemon.watchers.withLock { !$0.isEmpty } }, "the app does not watch the busy daemon")
        #expect(await fixture.eventually { clock.sleeperCount == 1 }, "no deadline waits for the cap")
        clock.advance(.seconds(599))
        try? await Task.sleep(for: .milliseconds(200))  // let a wrongly early handoff show
        #expect(!fixture.daemon.shutDown.withLock { $0 }, "a busy daemon was handed off before the cap")

        clock.advance(.seconds(1))
        #expect(await fixture.eventually { fixture.launches == 1 }, "the cap passed and the daemon was not handed off")
        #expect(fixture.daemon.shutDown.withLock { $0 })
        #expect(await fixture.eventually { !agentPaneProcessIsRunning(fixture.oldPid) })
    }

    /// An update replaces the bundled acpmux while the app and its daemon run (an in-place
    /// bundle update): the next reconnect hands the daemon off.
    @Test func aReconnectAfterTheBundledBuildChangesHandsOff() async throws {
        let fixture = try QuietFixture(agentHosts: true, daemonBuild: "same")
        defer { fixture.remove() }
        try fixture.writeBundled(build: "same")
        let host = fixture.host()

        _ = try? await host.prewarm()
        #expect(!fixture.daemon.shutDown.withLock { $0 }, "a daemon of this app's build was handed off")

        try fixture.writeBundled(build: fixture.newBuild)
        _ = try? await host.reconnectHandshake(sessionId: "s")
        #expect(fixture.daemon.shutDown.withLock { $0 }, "the reconnect kept the old daemon")
        #expect(fixture.launches == 1)
    }

    /// The daemon started after a handoff keeps answering with the old build: the app starts it
    /// once more, then the chat says acpmux did not start and the log says why.
    @Test func aStartThatIsNotHealthyIsRetriedOnceThenReported() async throws {
        let fixture = try QuietFixture(agentHosts: true, answersNewBuildAfterShutdown: false)
        defer { fixture.remove() }
        let host = fixture.host()

        await #expect(throws: AgentPaneHostError.daemonFailed(logPath: fixture.environment.logPath, cause: .unhealthyAfterRestart)) {
            try await host.prewarm()
        }
        #expect(fixture.launches == 2)
        #expect(fixture.log.contains(AcpmuxFailureCause.unhealthyAfterRestart.logText))
        let message = AgentPaneHostError.userMessage(for: AgentPaneHostError.daemonFailed(
            logPath: fixture.environment.logPath, cause: .unhealthyAfterRestart))
        #expect(message.contains(fixture.environment.logPath))
    }
}

/// A temp home whose bundled `acpmux` prints a build and, as a daemon, only its ready line; a
/// `sleep` child standing for the old daemon's process; and the stand-in daemon on the socket.
struct QuietFixture {
    let root: URL
    let tag = String(UUID().uuidString.prefix(8))
    let environment: AcpmuxEnvironment
    let sleeper: Process
    let daemon: StubDaemon
    var newBuild: String { "new-\(tag)" }
    var oldPid: Int32 { sleeper.processIdentifier }
    var launches: Int {
        ((try? String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    var log: String { (try? String(contentsOfFile: environment.logPath, encoding: .utf8)) ?? "" }

    init(agentHosts: Bool, daemonBuild: String = "old", answersNewBuildAfterShutdown: Bool = true) throws {
        root = URL(fileURLWithPath: "/tmp/aqh-\(tag)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let socketPath = home.appendingPathComponent("s.sock").path
        try Self.writeStandIn(at: bin.appendingPathComponent("acpmux"), build: "new-\(tag)", root: root)
        environment = try #require(AcpmuxEnvironment.resolve(
            build: nil, bundledBinDirectory: bin, environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socketPath],
            executableOverride: nil))
        FileManager.default.createFile(atPath: environment.logPath, contents: nil)
        sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        daemon = try StubDaemon(socketPath: socketPath, home: home.path, pid: sleeper.processIdentifier,
                                build: daemonBuild, agentHosts: agentHosts,
                                buildAfterShutdown: answersNewBuildAfterShutdown ? "new-\(tag)" : nil)
    }

    static func writeStandIn(at url: URL, build: String, root: URL) throws {
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'acpmux 0.1.0 (\(build))'; exit 0; fi
        echo started >> '\(root.path)/launches'
        echo '{"ready":true,"webUrl":"http://127.0.0.1:9/?token=t"}' >&3
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Replaces the bundled acpmux with one of `build`, as an in-place update does.
    func writeBundled(build: String) throws {
        try Self.writeStandIn(at: environment.executable, build: build, root: root)
    }

    /// A host that hands stale daemons off when quiet (its wait on `quietClock`, cap 600 s) and
    /// never restarts one for not answering.
    func host(quietClock: AcpmuxWatchClock = AcpmuxWatchClock()) -> AcpmuxHost {
        AcpmuxHost(environment: environment, unresponsive: AcpmuxUnresponsiveWatch(clock: AcpmuxWatchClock()),
                   quietHandoff: AcpmuxQuietHandoff(clock: quietClock, cap: .seconds(600)),
                   restartsUnresponsive: { false }, handsOffWhenQuiet: { true })
    }

    /// Waits (bounded) until `condition` holds. The old daemon's exit event can come before the
    /// process table shows it gone.
    func eventually(_ condition: @escaping () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    func remove() {
        daemon.stop()
        kill(sleeper.processIdentifier, SIGKILL)
        try? FileManager.default.removeItem(at: root)
    }
}

/// A unix socket served by this test process: `_acpmux/status` names `pid`, `home` and `build`;
/// `_acpmux/sessions` lists one session that runs a turn while `busy`; `_acpmux/watch` keeps the
/// connection for ``notify(kind:)``; `_acpmux/shutdown` ends `pid` and from then on answers with
/// `buildAfterShutdown`, as the daemon the app starts next would.
nonisolated final class StubDaemon: Sendable {
    let busy = Mutex(false)
    let shutDown = Mutex(false)
    let watchers = Mutex<Set<Int32>>([])
    private let build: Mutex<String>
    private let buildAfterShutdown: String?
    private let agentHosts: Bool
    private let descriptor: Int32
    private let path: String

    init(socketPath: String, home: String, pid: Int32, build: String, agentHosts: Bool, buildAfterShutdown: String?) throws {
        path = socketPath
        self.build = Mutex(build)
        self.buildAfterShutdown = buildAfterShutdown
        self.agentHosts = agentHosts
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8)
            buffer[socketPath.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        let listener = descriptor
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { self.serve(client, home: home, pid: pid) }
            }
        }
    }

    /// Sends `_acpmux/session_changed` of `kind` to every watching connection.
    func notify(kind: String) {
        let note: [String: Any] = ["jsonrpc": "2.0", "method": "_acpmux/session_changed",
                                   "params": ["sessionId": "s", "kind": kind, "recordKind": kind, "seq": 1] as [String: Any]]
        guard var data = try? JSONSerialization.data(withJSONObject: note) else { return }
        data.append(0x0A)
        for client in watchers.withLock({ $0 }) { _ = data.withUnsafeBytes { send(client, $0.baseAddress, data.count, 0) } }
    }

    private func result(for method: String, client: Int32, home: String, pid: Int32) -> [String: Any] {
        switch method {
        case "_acpmux/status":
            return ["webUrl": "ws://127.0.0.1:9/?token=t", "pid": Int(pid), "build": build.withLock { $0 },
                    "agentHosts": agentHosts, "home": home]
        case "_acpmux/sessions", "_acpmux/watch":
            if method == "_acpmux/watch" { _ = watchers.withLock { $0.insert(client) } }
            var session: [String: Any] = ["sessionId": "s", "status": "idle", "turn": NSNull(), "pendingPermissions": 0]
            if busy.withLock({ $0 }) { session["turn"] = ["prompt": "p", "startedAt": 5] as [String: Any] }
            return ["sessions": [session]]
        case "_acpmux/shutdown":
            shutDown.withLock { $0 = true }
            if let buildAfterShutdown { build.withLock { $0 = buildAfterShutdown } }
            kill(pid, SIGTERM)
            return [:]
        default:
            return [:]
        }
    }

    private func serve(_ client: Int32, home: String, pid: Int32) {
        defer {
            _ = watchers.withLock { $0.remove(client) }
            close(client)
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer += Data(chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"], let method = object["method"] as? String else { continue }
                let reply: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                            "result": result(for: method, client: client, home: home, pid: pid)]
                guard var data = try? JSONSerialization.data(withJSONObject: reply) else { continue }
                data.append(0x0A)
                _ = data.withUnsafeBytes { send(client, $0.baseAddress, data.count, 0) }
            }
        }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }
}
