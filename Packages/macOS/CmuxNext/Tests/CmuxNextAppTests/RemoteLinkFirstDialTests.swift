@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing

/// cmuxterm-hq#7766 step 3: the link process (`cmux-tui remote connect`) starts at once and owns
/// everything up to ready, the SSH probe and every redial included. The app ran its own SSH probe
/// first and retried it on a timer while the machine was unreachable, so the link that redials by
/// itself never started until the app's probe got through. Now the app has no timer of its own: it
/// reads the link's state from `PATH.admin`, passes a person's deadline down with `await-ready`, and
/// says once why a link that exited before it connected did.
///
/// The stand-in link (a script in place of the bundled cmux-tui) answers `link-state` and
/// `await-ready` on its admin socket, says on stderr when a dial failed, and serves a daemon on its
/// local socket once the machine is reachable (`reachable`), as Rust does when the network comes back.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteLinkFirstDialTests {
    private static let link = #"""
    #!/usr/bin/python3 -u
    import json, os, socket, sys, threading, time
    ROOT = os.path.dirname(os.path.abspath(__file__))
    def p(name): return os.path.join(ROOT, name)
    def log(name, line):
        with open(p(name), 'a') as out: out.write(line + '\n')
    if sys.argv[1:2] == ['remote-probe']:
        print(json.dumps({'app': 'cmux-tui', 'version': '0.1.0', 'remote_protocol': 7, 'os': 'macos', 'arch': 'aarch64'}))
        sys.exit(0)
    args = sys.argv[1:]
    local = args[args.index('--local-socket') + 1]
    log('spawns', 'spawn')
    if os.path.exists(p('refuse')):
        print('remote connect: the remote cmux-tui is older than this client [remote-protocol-older]', file=sys.stderr, flush=True)
        sys.exit(1)
    REFUSED = 'ssh: connect to host drill port 22: Connection refused'
    state = {'state': 'connecting', 'reason': None}
    lock = threading.Condition()
    def reachable(): return os.path.exists(p('reachable'))
    def admin(conn):
        try:
            stream = conn.makefile('rwb')
            request = json.loads(stream.readline())
            log('admin.log', json.dumps(request, sort_keys=True))
            if request.get('method') == 'await-ready':
                if os.path.exists(p('up-on-wake')):
                    open(p('reachable'), 'w').close()
                deadline = time.time() + request['within_ms'] / 1000
                with lock:
                    while state['state'] != 'connected' and time.time() < deadline:
                        lock.wait(0.05)
                    result = dict(state) if state['state'] == 'connected' else {'state': 'down', 'reason': state['reason']}
            else:
                with lock:
                    result = dict(state)
            result = {k: v for k, v in result.items() if v is not None}
            stream.write((json.dumps({'ok': True, 'result': result}) + '\n').encode())
            stream.flush()
        finally:
            conn.close()
    daemons = []
    down = [False]
    def daemon(conn):
        if down[0]:
            conn.close()
            return
        daemons.append(conn)
        stream = conn.makefile('rwb')
        try:
            for line in stream:
                frame = json.loads(line)
                data = {}
                if frame.get('cmd') == 'identify':
                    data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'first-dial', 'pid': 4242, 'capabilities': []}
                stream.write((json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}) + '\n').encode())
                stream.flush()
        except Exception:
            pass
        finally:
            conn.close()
    def serve(path, handler):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(path)
        listener.listen(16)
        def loop():
            while True:
                conn, _ = listener.accept()
                threading.Thread(target=handler, args=(conn,), daemon=True).start()
        threading.Thread(target=loop, daemon=True).start()
    def snapshot(name):
        print(json.dumps({'event': 'connection-snapshot', 'local_socket': local, 'connection': {
            'session_id': 's', 'generation': 1, 'state': name, 'lane_bindings': [], 'physical_link_count': 1,
            'transport': {'provider': 'ssh', 'route': 'ssh://drill'}}}), flush=True)
    serve(local + '.admin', admin)
    print('remote connect: link socket ready', file=sys.stderr, flush=True)
    if not reachable() and not os.path.exists(p('stall')):
        with lock:
            state.update(state='disconnected', reason=REFUSED)
        print('remote connect: ' + REFUSED + '; redialing', file=sys.stderr, flush=True)
    while not reachable():
        time.sleep(0.05)
    serve(local, daemon)
    with lock:
        state.update(state='connected', reason=None)
        lock.notify_all()
    snapshot('connected')
    while not os.path.exists(p('drop')):
        time.sleep(0.05)
    down[0] = True
    for conn in list(daemons):
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
    with lock:
        state.update(state='reconnecting', reason='link lost')
    snapshot('reconnecting')
    while not os.path.exists(p('back')):
        time.sleep(0.05)
    down[0] = False
    with lock:
        state.update(state='connected', reason=None)
        lock.notify_all()
    snapshot('connected')
    while True:
        time.sleep(1)
    """#

    /// A short temp root holding the stand-in link, its marks and its logs, and the machine's session.
    private struct Fixture {
        let root: URL
        let session: SSHMachineSession

        init(_ marks: [String] = []) throws {
            root = URL(fileURLWithPath: "/tmp/rlfd-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let tui = root.appendingPathComponent("cmux-tui")
            try RemoteLinkFirstDialTests.link.write(to: tui, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tui.path)
            for name in marks { FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil) }
            // A host no ssh reaches: the app must never need ssh before the link connects.
            let host = try SSHHost(destination: SSHDestination(parsing: "first-dial-\(UUID().uuidString.prefix(6)).invalid"))
            session = SSHMachineSession(host: host, binary: tui, paths: SSHPaths(root: root.appendingPathComponent("p")),
                                        environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        }

        func mark(_ name: String) { FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil) }

        func lines(_ name: String) -> [String] {
            ((try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        var spawns: Int { lines("spawns").count }

        /// Opens the machine as `SSHMachineSession.connect()` does, with no capability the stand-in lacks.
        func open() async {
            await session.link.handle(.connect)
            let link = session.link
            session.daemon.start(remote: { try await link.socketPath() }, requiredCapabilities: [], followsLink: true)
        }

        var connected: Bool { if case .connected = session.daemon.store.connectionState { true } else { false } }

        func close() {
            session.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition(), "\(what)")
    }

    /// Cold open with the machine unreachable, then reachable: the link starts at once, the machine says
    /// why it is not up from the link's own state, the app makes no timed attempt, and the link alone
    /// brings it up when the network comes back.
    @Test func aColdOpenOfAnUnreachableMachineRecoversThroughTheLinkAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        await fixture.open()
        try await Self.waitUntil("the link's reason shows") {
            if case .unreachable(let text) = fixture.session.linkStatus { text.contains("Connection refused") } else { false }
        }
        #expect(fixture.lines("admin.log").contains(#"{"method": "link-state"}"#), "the status came from the link's state")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(fixture.spawns == 1, "the app restarted a link that redials by itself (\(fixture.spawns) spawns)")
        #expect(!fixture.connected)
        fixture.mark("reachable")
        try await Self.waitUntil("the link brought the machine up") { fixture.connected }
        #expect(fixture.spawns == 1)
        #expect(fixture.session.linkStatus == .connected)
        #expect(!fixture.lines("admin.log").contains { $0.contains("await-ready") }, "nothing but the link redialed")
    }

    /// A person's Reconnect while the link is still on its first dial passes the person's deadline down
    /// (`await-ready`): the link dials at once, over the same process.
    @Test func reconnectPassesThePersonsDeadlineDownToTheLink() async throws {
        let fixture = try Fixture(["up-on-wake"])
        defer { fixture.close() }
        await fixture.open()
        try await Self.waitUntil("the first dial failed") { fixture.session.linkStatus.needsRecovery }
        fixture.session.wake(.user, deadline: .seconds(3))
        try await Self.waitUntil("Reconnect brought the machine up") { fixture.connected }
        #expect(fixture.lines("admin.log").contains(#"{"method": "await-ready", "within_ms": 3000}"#), "\(fixture.lines("admin.log"))")
        #expect(fixture.spawns == 1, "Reconnect restarted the link (\(fixture.spawns) spawns)")
    }

    /// Review of #39103, F1: a cold open sends its `await-ready` before the link process exists, so the
    /// request was dropped and the person's deadline never reached the link. It is now kept with its
    /// original deadline until the link answers, and goes to it with what is left.
    @Test func aColdOpenKeepsThePersonsDeadlineUntilTheLinkAnswers() async throws {
        let fixture = try Fixture(["up-on-wake"])
        defer { fixture.close() }
        fixture.session.connect(deadline: .seconds(4))
        try await Self.waitUntil("the person's wait reached the link and brought it up") { fixture.session.linkStatus == .connected }
        let waits = fixture.lines("admin.log").compactMap { line -> Int? in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  object["method"] as? String == "await-ready" else { return nil }
            return object["within_ms"] as? Int
        }
        #expect(waits.count == 1, "\(fixture.lines("admin.log"))")
        #expect(waits.allSatisfy { $0 > 0 && $0 <= 4000 }, "the original deadline, less the time before the link answered: \(waits)")
        #expect(fixture.spawns == 1)
    }

    /// Review of #39200, F2: a first dial that stalls says nothing on stderr, so a cold open's wait that
    /// was forwarded only on a failed-dial line never reached the link within its deadline. The link
    /// writes a line once its socket answers, and the wait goes to it then.
    @Test func aColdOpenReachesAStalledFirstDialBeforeItsDeadline() async throws {
        let fixture = try Fixture(["up-on-wake", "stall"])
        defer { fixture.close() }
        let opened = ContinuousClock.now
        fixture.session.connect(deadline: .seconds(3))
        try await Self.waitUntil("the person's wait reached the stalled link") {
            fixture.lines("admin.log").contains { $0.contains("await-ready") }
        }
        #expect(ContinuousClock.now - opened < .seconds(3), "the wait reached the link only after its deadline")
        try await Self.waitUntil("the wait brought the machine up") { fixture.session.linkStatus == .connected }
        #expect(fixture.spawns == 1)
    }

    /// The network drops and returns under a running link: the machine reads reconnecting, then the
    /// link's own recovery wakes the daemon connection, over the same process.
    @Test func aDropAndReturnRecoversOverTheSameLink() async throws {
        let fixture = try Fixture(["reachable"])
        defer { fixture.close() }
        await fixture.open()
        try await Self.waitUntil("connected") { fixture.connected }
        fixture.mark("drop")
        try await Self.waitUntil("reads reconnecting") { fixture.session.linkStatus == .reconnecting }
        fixture.mark("back")
        try await Self.waitUntil("back up") { fixture.connected && fixture.session.linkStatus == .connected }
        #expect(fixture.spawns == 1, "the drop restarted the link (\(fixture.spawns) spawns)")
    }

    /// A link that exits before it connected (here the machine's cmux-tui is too old) says why once:
    /// the install offer shows and nothing retries it.
    @Test func aLinkRefusalIsSurfacedOnceAndNotRetried() async throws {
        let fixture = try Fixture(["refuse"])
        defer { fixture.close() }
        await fixture.open()
        try await Self.waitUntil("the refusal shows") { fixture.session.linkStatus == .needsInstall(.refused(.protocolOlder)) }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(fixture.spawns == 1, "the app retried a refused link (\(fixture.spawns) spawns)")
        #expect(fixture.session.linkStatus == .needsInstall(.refused(.protocolOlder)))
    }

    /// Nothing in the app watches the network for a link-following machine: the link does.
    @Test func aLinkFollowingServiceRunsNoNetworkMonitorOfItsOwn() {
        let daemon = DaemonService(machineID: "ssh:first-dial-\(UUID().uuidString)")
        daemon.start(remote: { throw DaemonError.notConnected }, followsLink: true)
        #expect(!daemon.watchesNetwork)
        daemon.shutdownConnection()
        let legacy = DaemonService(machineID: "ssh:first-dial-legacy-\(UUID().uuidString)")
        legacy.start(remote: { throw DaemonError.notConnected })
        #expect(legacy.watchesNetwork, "a route that does not redial by itself keeps its network wake")
        legacy.shutdownConnection()
    }
}
