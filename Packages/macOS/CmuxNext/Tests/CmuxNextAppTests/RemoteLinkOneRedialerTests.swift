@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing

/// cmuxterm-hq#7766 step 2: a remote machine's link (`cmux-tui remote connect`) is the only layer
/// that redials. The app made timed redials on top of it (a first-connect pacer nested in an outer
/// pacer, the connection's own reconnect loop, a network monitor, and a Reconnect that killed and
/// restarted the link client "with a new retry budget"), so one dead link became a burst of dials.
/// Now the app makes one attempt and then waits for the link's state or an event.
/// Counts endpoint calls; off the main actor, so the endpoint closure can call it.
private nonisolated final class RemoteLinkCalls: Sendable {
    private let count = Mutex(0)
    func hit() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteLinkOneRedialerTests {
    private static func service(_ calls: RemoteLinkCalls, followsLink: Bool) -> DaemonService {
        let daemon = DaemonService(machineID: "ssh:one-redialer-\(UUID().uuidString)")
        daemon.start(remote: {
            calls.hit()
            throw DaemonError.notConnected
        }, followsLink: followsLink)
        return daemon
    }

    @Test func aLinkThatFollowsItsOwnStateGetsOneFirstAttemptAndNoTimedRetries() async throws {
        let calls = RemoteLinkCalls()
        let daemon = Self.service(calls, followsLink: true)
        try await Task.sleep(for: .milliseconds(2000))
        daemon.shutdownConnection()
        #expect(calls.value == 1, "the app dialed a link that redials by itself \(calls.value) times")
    }

    /// The legacy route (a server's own socket or bridge, a Cloud ticket) still paces its own retries:
    /// this is what the link route no longer stacks on its link.
    @Test func theLegacyRouteStillRetriesOnATimer() async throws {
        let calls = RemoteLinkCalls()
        let daemon = Self.service(calls, followsLink: false)
        try await Task.sleep(for: .milliseconds(2000))
        daemon.shutdownConnection()
        #expect(calls.value >= 2, "the legacy first-connect pacer made \(calls.value) attempts")
    }

    @Test func theLinksStateWakesTheWaitingAttemptOnce() async throws {
        let calls = RemoteLinkCalls()
        let daemon = Self.service(calls, followsLink: true)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(calls.value == 1, "the first attempt, and no timed retry")
        daemon.retryWake.fire()
        try await Task.sleep(for: .milliseconds(1000))
        #expect(calls.value == 2, "one wake (the link reported connected) makes exactly one attempt")
        daemon.shutdownConnection()
    }

    /// Review of 5b0b637, F2: a link process that keeps reporting connected and exiting before the daemon's
    /// handshake fired the retry wake each time, past every budget. Link wakes are bounded until a
    /// connection comes up or a person reconnects; Reconnect still wakes it.
    @Test func linkWakesAreBoundedUntilAConnectionOrAReconnect() async throws {
        let calls = RemoteLinkCalls()
        let daemon = Self.service(calls, followsLink: true)
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<25 {
            daemon.linkWake()
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.value <= 1 + BootstrapRetry.link.timedRetries, "link wakes made \(calls.value) attempts")
        let bounded = calls.value
        daemon.reconnectNow()
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.value == bounded + 1, "Reconnect still wakes it")
        daemon.linkWake()
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.value == bounded + 2, "Reconnect gives the link wakes their budget back")
        daemon.shutdownConnection()
    }

    /// A machine unreachable at launch has no link process yet, so nothing in Rust watches its network:
    /// the network coming back still wakes its first attempt, with no app action.
    @Test func aNeverConnectedLinkStillWakesOnTheNetwork() async throws {
        let calls = RemoteLinkCalls()
        let daemon = Self.service(calls, followsLink: true)
        #expect(daemon.watchesNetwork, "an SSH machine unreachable at launch would never come back by itself")
        daemon.shutdownConnection()
        #expect(!daemon.watchesNetwork)
    }

    /// The link reporting connected again, or its process exiting, wakes the daemon connection; other
    /// changes (a failure, an install) do not.
    @Test func onlyTheLinksUpAndLossWakeTheDaemon() {
        typealias S = SSHConnectionMachine.Status
        #expect(S.connected.wakesDaemon(after: .reconnecting))
        #expect(S.connected.wakesDaemon(after: .connecting))
        #expect(S.connecting.wakesDaemon(after: .connected), "the link process exited")
        #expect(S.connecting.wakesDaemon(after: .reconnecting), "the link process exited")
        #expect(!S.connecting.wakesDaemon(after: .offline))
        #expect(!S.reconnecting.wakesDaemon(after: .connected), "the link redials by itself")
        #expect(!S.unreachable("x").wakesDaemon(after: .connecting))
        #expect(!S.installing.wakesDaemon(after: .connecting))
    }

    /// The app no longer caps the link's attempts: `remote connect` stays up under its own budget.
    @Test func theLinkGetsNoAttemptCap() throws {
        let host = try SSHHost(destination: SSHDestination(parsing: "nohost.invalid"))
        let args = SSHCommandLine().link(host, clientStateDir: "/tmp/state", localSocket: "/tmp/link.sock")
        #expect(!args.contains("--reconnect-attempts"), "\(args)")
        #expect(args.contains("--local-socket"))
    }
}

/// A connection over a link that redials by itself (``RetryPolicy/linkReconnect``) makes one attempt
/// when it drops, then waits for an event; the timed reconnect policy made several in the same time.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LinkReconnectPolicyTests {
    @Test func aDropGetsOneAttemptThenEventsOnly() {
        var pacer = RetryPacer(.linkReconnect)
        pacer.noteDrop()
        #expect(pacer.failed() != nil, "the drop's one attempt")
        #expect(pacer.failed() == nil, "a failed attempt waits for an event")
        #expect(pacer.waitsForEventOnly)
        var first = RetryPacer(.linkFirstConnect)
        #expect(first.failed() == nil, "a failed first attempt waits for an event")
    }
}

/// Review of 5d8ee21, F2: each handshake reset the link's reconnect spacing, so a peer that accepted and
/// closed at once got an attempt per drop with no bound. Drops now spend tokens of one budget that lives
/// across connections: 3, one back every 10 s, and an explicit reconnect fills it.
@Suite struct DropBudgetTests {
    @Test func threeDropsThenTheNextWaitsForTheRefill() {
        var budget = DropBudget(capacity: 3, refill: .seconds(10))
        let start = ContinuousClock.now
        #expect(budget.take(at: start) == nil)
        #expect(budget.take(at: start + .milliseconds(100)) == nil)
        #expect(budget.take(at: start + .milliseconds(200)) == nil)
        let wait = budget.take(at: start + .milliseconds(300))
        #expect(wait == .milliseconds(9700), "the fourth drop waits for the first token back (\(String(describing: wait)))")
        #expect(budget.take(at: start + .seconds(10)) == nil, "one token back after 10 s")
        #expect(budget.take(at: start + .seconds(10) + .milliseconds(1)) != nil, "only one")
        let full = budget.isFull(at: start + .seconds(40))
        #expect(full, "all back after the refills")
    }

    @Test func anExplicitReconnectFillsIt() {
        var budget = DropBudget(capacity: 3, refill: .seconds(10))
        let now = ContinuousClock.now
        for _ in 0..<3 { _ = budget.take(at: now) }
        #expect(budget.take(at: now) != nil)
        budget.fill()
        #expect(budget.take(at: now) == nil)
    }

    @Test func aPacerSpendsATokenPerDropAndNeverResetsItOnAConnection() {
        var pacer = RetryPacer(.linkReconnect)
        for drop in 1...3 {
            pacer.noteDrop()
            let delay = pacer.failed()
            #expect(delay != nil && delay! <= .seconds(2), "drop \(drop) gets its attempt after the backoff")
            pacer.woke(.timer)
            pacer.reset() // a restoring owner, or any other reset: the budget stays spent
        }
        pacer.noteDrop()
        let wait = pacer.failed()
        #expect(pacer.waitsForToken)
        #expect(wait != nil && wait! > .seconds(9), "the fourth drop in a row waits for a token (\(String(describing: wait)))")
        pacer.woke(.event)
        #expect(!pacer.waitsForToken)
        #expect(pacer.failed() == nil, "a failed attempt after it waits for an event only")
        pacer.refillDropBudget()
        pacer.noteDrop()
        #expect(pacer.failed().map { $0 <= .seconds(2) } == true, "an explicit reconnect refilled the budget")
    }
}

/// Review of 5d8ee21, F1: after the reconnect met an incompatible daemon (`unsupportedProtocol`,
/// `missingCapabilities`) the connection ended (`.failed`), and Reconnect did nothing: it only woke a
/// `.disconnected` daemon. Now Reconnect starts a new attempt there; the link's automatic wakes don't.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteLinkReconnectAfterFailureTests {
    /// The n-th connection (0-based, counted in the identify log): 0 serves and drops 0.3 s after its
    /// handshake, 1 answers an unsupported protocol, later ones serve and stay.
    private static let script = #"""
    import json, os, sys, time
    print('{"ok":true}', file=sys.stderr, flush=True)
    log = sys.argv[1]
    nth = None
    for line in sys.stdin:
        frame = json.loads(line)
        data = {}
        if frame.get('cmd') == 'identify':
            nth = len(open(log).read().splitlines()) if os.path.exists(log) else 0
            with open(log, 'a') as out:
                out.write('identify\n')
            data = {'app': 'cmux-tui', 'protocol': 99 if nth == 1 else 12, 'generation': 'reconnect-after-failure-%d' % nth,
                    'pid': 4242, 'capabilities': []}
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
        if frame.get('cmd') == 'subscribe' and nth == 0:
            time.sleep(0.3)
            sys.exit(0)
    """#

    private static func identifies(_ log: String) -> Int {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition())
    }

    @Test func reconnectAfterAnUnsupportedProtocolStartsANewAttemptAndRecovers() async throws {
        let log = "/private/tmp/cn-reconnect-failed-\(UUID().uuidString.prefix(8)).log"
        defer { try? FileManager.default.removeItem(atPath: log) }
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, log])
        let socket = "/tmp/cn-reconnect-failed-\(UUID().uuidString.prefix(8)).sock"
        let daemon = DaemonService(machineID: "ssh:reconnect-after-failure-\(UUID().uuidString)")
        defer { daemon.shutdownConnection() }
        daemon.start(remote: { socket }, bridge: bridge, requiredCapabilities: [], followsLink: true)
        // The first connection drops; its reconnect meets an unsupported protocol and ends for good.
        try await Self.waitUntil { if case .failed = daemon.store.connectionState { true } else { false } }
        #expect(Self.identifies(log) == 2)
        // The link's automatic wake (it reported connected) does not retry an incompatible daemon.
        daemon.retryWake.fire()
        try await Task.sleep(for: .milliseconds(700))
        #expect(Self.identifies(log) == 2, "an automatic wake retried an incompatible daemon")
        // Reconnect does: the session routes it to the daemon (`daemonDown`), which makes a new attempt.
        let host = try SSHHost(destination: SSHDestination(parsing: "reconnect-after-failure.invalid"))
        let session = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                        paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/reconnect-after-failure-tests")),
                                        environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        session.daemon.store.markFailed("cmux-tui protocol 99 is not supported (need 12)")
        #expect(session.daemonDown, "a failed (ended) daemon connection is down: Reconnect must reach it")
        #expect(SSHConnectionMachine.Status.connected.reconnectStep(daemonConnected: true, daemonFailed: false,
                                                                    daemonDown: session.daemonDown) == .wake)
        daemon.reconnectNow()
        try await Self.waitUntil { if case .connected = daemon.store.connectionState { true } else { false } }
        #expect(Self.identifies(log) == 3, "Reconnect made one new attempt")
    }

    /// Review of 146f273, F2: the explicit-Reconnect count was taken once per connection, so a Reconnect
    /// that recovered an earlier drop also retried a later incompatible daemon with no new request. Each
    /// attempt now consumes the requests made before it.
    @Test func aReconnectThatRecoveredADropDoesNotAlsoRetryALaterIncompatibleDaemon() async throws {
        let log = "/private/tmp/cn-reconnect-consumed-\(UUID().uuidString.prefix(8)).log"
        defer { try? FileManager.default.removeItem(atPath: log) }
        // Connections 0 and 1 serve and drop 0.3 s after their handshake, 2 answers an unsupported
        // protocol, later ones serve and stay.
        let script = #"""
        import json, os, sys, time
        print('{"ok":true}', file=sys.stderr, flush=True)
        log = sys.argv[1]
        nth = None
        for line in sys.stdin:
            frame = json.loads(line)
            data = {}
            if frame.get('cmd') == 'identify':
                nth = len(open(log).read().splitlines()) if os.path.exists(log) else 0
                with open(log, 'a') as out:
                    out.write('identify\n')
                data = {'app': 'cmux-tui', 'protocol': 99 if nth == 2 else 12, 'generation': 'consumed-%d' % nth,
                        'pid': 4242, 'capabilities': []}
            print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
            if frame.get('cmd') == 'subscribe' and nth in (0, 1):
                time.sleep(0.3)
                sys.exit(0)
        """#
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, log])
        let socket = "/tmp/cn-reconnect-consumed-\(UUID().uuidString.prefix(8)).sock"
        let calls = Mutex(0)
        let daemon = DaemonService(machineID: "ssh:reconnect-consumed-\(UUID().uuidString)")
        defer { daemon.shutdownConnection() }
        daemon.start(remote: {
            // The drop's attempt fails (call 2), so the connection parks until a Reconnect.
            if calls.withLock({ $0 += 1; return $0 }) == 2 { throw DaemonError.notConnected }
            return socket
        }, bridge: bridge, requiredCapabilities: [], followsLink: true)
        try await Self.waitUntil { calls.withLock { $0 } == 2 && daemon.store.retriesSpent }
        // A person's Reconnect recovers the drop (connection 1), which drops again; its reconnect meets
        // an unsupported protocol (connection 2) and the connection ends for good.
        daemon.reconnectNow()
        try await Self.waitUntil { Self.identifies(log) == 3 && { if case .failed = daemon.store.connectionState { true } else { false } }() }
        daemon.retryWake.fire()
        try await Task.sleep(for: .milliseconds(700))
        #expect(calls.withLock { $0 } == 4, "the earlier Reconnect retried the incompatible daemon with no new request")
        daemon.reconnectNow()
        try await Self.waitUntil { if case .connected = daemon.store.connectionState { true } else { false } }
        #expect(Self.identifies(log) == 4)
    }

    /// Review of 8cbf436, F1: the explicit-Reconnect gate also held a blocked endpoint (SSH auth, host key,
    /// install). After the person fixed their agent or known_hosts, app activation opened the SSH gate and
    /// fired the retry wake, and the wait ignored it. Only an incompatible daemon needs a Reconnect.
    @Test func aBlockedEndpointRetriesOnActivationWithNoReconnect() async throws {
        let calls = RemoteLinkCalls()
        let host = try SSHHost(destination: SSHDestination(parsing: "blocked-endpoint.invalid"))
        let session = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                        paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/blocked-endpoint-tests")),
                                        environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer { session.daemon.shutdownConnection() }
        session.daemon.start(remote: {
            calls.hit()
            throw DaemonError.endpointBlocked("Host key verification failed.")
        }, requiredCapabilities: [], followsLink: true)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(calls.value == 1, "the blocked first attempt, then a wait for an event")
        // The person fixed known_hosts and came back to the app: activation opens the gate and wakes the daemon.
        session.wake(.appActivated)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(calls.value == 2, "activation retried a blocked endpoint with no Reconnect (\(calls.value) endpoint calls)")
    }
}

/// Review of dbe16be, F1: while the link has no process (its SSH probe or install fails while the host
/// boots, or its restart after an exit fails) nothing in the link redials, and the daemon connection
/// waited for an event that a host coming back up never sends locally. Until a link process runs, the
/// daemon connection keeps the base's bounded retry (``RetryPolicy/bootstrap``) and the network wake.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteLinkBootstrapRetryTests {
    /// Whether the stand-in link has a process, and its endpoint calls.
    private nonisolated final class StandInLink: Sendable {
        private let state = Mutex((running: false, calls: 0))
        var running: Bool { state.withLock { $0.running } }
        var calls: Int { state.withLock { $0.calls } }
        /// Notes one endpoint call; returns its number (1-based).
        func call(running: Bool) -> Int { state.withLock { $0.running = running; $0.calls += 1; return $0.calls } }
    }

    /// The n-th connection (0-based, counted in the identify log): 0 drops 0.3 s after its handshake when
    /// `argv[2]` is "drop", every other one serves and stays.
    private static let script = #"""
    import json, os, sys, time
    print('{"ok":true}', file=sys.stderr, flush=True)
    log, mode = sys.argv[1], sys.argv[2]
    nth = None
    for line in sys.stdin:
        frame = json.loads(line)
        data = {}
        if frame.get('cmd') == 'identify':
            nth = len(open(log).read().splitlines()) if os.path.exists(log) else 0
            with open(log, 'a') as out:
                out.write('identify\n')
            data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'bootstrap-%d' % nth, 'pid': 4242, 'capabilities': []}
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
        if frame.get('cmd') == 'subscribe' and nth == 0 and mode == 'drop':
            time.sleep(0.3)
            sys.exit(0)
    """#

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition())
    }

    private static func connected(_ daemon: DaemonService) -> Bool {
        if case .connected = daemon.store.connectionState { true } else { false }
    }

    @Test func aFirstProbeThatFailsIsRetriedOnATimerWithNoNetworkEvent() async throws {
        let log = "/private/tmp/cn-bootstrap-first-\(UUID().uuidString.prefix(8)).log"
        defer { try? FileManager.default.removeItem(atPath: log) }
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, log, "stay"])
        let socket = "/tmp/cn-bootstrap-first-\(UUID().uuidString.prefix(8)).sock"
        let link = StandInLink()
        let daemon = DaemonService(machineID: "ssh:bootstrap-first-\(UUID().uuidString)")
        defer { daemon.shutdownConnection() }
        daemon.start(remote: {
            // The first SSH probe fails (the host is still booting): no link process exists.
            guard link.call(running: link.calls > 0) > 1 else { throw DaemonError.launchFailed("ssh: connect to host: Connection refused") }
            return socket
        }, bridge: bridge, requiredCapabilities: [], followsLink: true, linkRunning: { link.running })
        try await Self.waitUntil { Self.connected(daemon) }
        #expect(link.calls == 2, "one timed retry after the failed probe (\(link.calls) endpoint calls)")
    }

    @Test func aLinkThatExitedAndWhoseRestartProbeFailedIsRestartedOnATimer() async throws {
        let log = "/private/tmp/cn-bootstrap-restart-\(UUID().uuidString.prefix(8)).log"
        defer { try? FileManager.default.removeItem(atPath: log) }
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, log, "drop"])
        let socket = "/tmp/cn-bootstrap-restart-\(UUID().uuidString.prefix(8)).sock"
        let link = StandInLink()
        let daemon = DaemonService(machineID: "ssh:bootstrap-restart-\(UUID().uuidString)")
        defer { daemon.shutdownConnection() }
        daemon.start(remote: {
            // 1: the link runs. 2: it exited and its restart probe fails. 3: the restart succeeds.
            let nth = link.call(running: link.calls != 1)
            if nth == 2 { throw DaemonError.launchFailed("ssh: connect to host: Connection timed out") }
            return socket
        }, bridge: bridge, requiredCapabilities: [], followsLink: true, linkRunning: { link.running })
        try await Self.waitUntil { link.calls >= 3 }
        try await Self.waitUntil { Self.connected(daemon) }
        #expect(link.calls == 3, "one timed restart after the failed restart probe (\(link.calls) endpoint calls)")
        #expect(daemon.watchesNetwork, "the network wake stays while the link may have no process")
    }
}
