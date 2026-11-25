@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextSidebar
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// HQ #4877 G4 and G5: an SSH machine's later drop reads as its link says, with a Reconnect that
/// retries the daemon over the same link (cmuxterm-hq#7766); and reconnect on use never takes over
/// a session another cmux daemon holds, which only a person's Reconnect may.
@MainActor @Suite(.serialized) struct SSHMachineLinkRecoveryTests {
    private static func session() throws -> SSHMachineSession {
        let host = try SSHHost(destination: SSHDestination(parsing: "nohost.invalid"))
        return SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                 paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/ssh-link-recovery-tests")),
                                 environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    private static func service(with session: SSHMachineSession? = nil) -> SSHService {
        let machines = MachineRegistry(local: DaemonService())
        if let session { machines.add(session) }
        return SSHService(machines: machines, bundleID: nil, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    private static func identity() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"ssh-link-recovery-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    // MARK: G4

    /// A later reconnect that parked (its attempt failed and it waits for an event) reads offline, so using
    /// the machine reconnects it (HQ #4877 G4); Reconnect wakes it over the same link client (cmuxterm-hq#7766).
    @Test func aSpentReconnectReadsOfflineNotConnecting() {
        for link: SSHConnectionMachine.Status in [.connecting, .connected, .reconnecting] {
            #expect(link.sidebarStatus(startupFailed: false, daemonConnected: false, compatibility: nil,
                                            retriesSpent: true) == .offline, "\(link)")
            #expect(link.sidebarStatus(startupFailed: false, daemonConnected: true, compatibility: nil,
                                            retriesSpent: true) == (link == .reconnecting ? .reconnecting : .connected))
        }
        #expect(SSHConnectionMachine.Status.connecting.sidebarStatus(startupFailed: false, daemonConnected: false, compatibility: nil) == .connecting)
        #expect(SSHConnectionMachine.Status.connected.sidebarStatus(startupFailed: true, daemonConnected: false, compatibility: nil,
                                        retriesSpent: true) == .failed, "A startup failure keeps its own word")
        #expect(MachineLinkState.reconnectsOnUse(.offline), "Using the machine reconnects it")
    }

    @Test func theStoreMarksSpentRetriesUntilTheNextConnect() throws {
        let store = DaemonStore()
        store.connectionState = .disconnected("link lost")
        store.noteRetriesSpent(true)
        #expect(store.retriesSpent)
        _ = DaemonConnectionChange.connected(try Self.identity(), nil).apply(to: store)
        #expect(!store.retriesSpent, "A reconnect clears it")
        store.noteRetriesSpent(true)
        #expect(!store.retriesSpent, "A hop that lands after the link came back changes nothing")
    }

    /// Review of 5b0b637, F1: a fast reconnect parks before its disconnect drains on the next frame; the
    /// store still read connected and dropped the mark, so the header read Connecting forever. The mark
    /// now applies when the disconnect drains.
    @Test func aParkThatLandsBeforeTheDisconnectDrainsStillMarksTheStore() throws {
        let store = DaemonStore()
        _ = DaemonConnectionChange.connected(try Self.identity(), nil).apply(to: store)
        store.noteRetriesSpent(true)
        #expect(!store.retriesSpent, "still connected until the disconnect drains")
        _ = DaemonConnectionChange.disconnected("link lost").apply(to: store)
        #expect(store.retriesSpent, "the park that came first applies with the disconnect")
        _ = DaemonConnectionChange.connected(try Self.identity(), nil).apply(to: store)
        #expect(!store.retriesSpent)
        _ = DaemonConnectionChange.disconnected("link lost").apply(to: store)
        #expect(!store.retriesSpent, "a connect clears a pending park")
    }

    /// Review of #38925, F1: a park delivered after the link already recovered (its hop to main landed
    /// after the next connection applied) was kept as pending, so the next disconnect read Offline.
    /// Each park now carries its attempt's serial; one older than the connection applied is stale.
    @Test func aParkDeliveredAfterTheRecoveryDoesNotMarkTheNextDisconnect() throws {
        let store = DaemonStore()
        let source = UUID()
        let identity = try Self.identity()
        func connected(_ serial: UInt64) -> DaemonConnectionChange {
            .connected(identity, DaemonEventEnvelope(sequence: DaemonEventEnvelope.sequence(serial: serial, index: 0),
                                                     event: .connected(identity, generationChanged: false), sourceID: source))
        }
        _ = connected(1).apply(to: store)
        _ = DaemonConnectionChange.disconnected("link lost").apply(to: store)
        // Attempt 2 parks; attempt 3 connects before attempt 2's notice reaches main.
        _ = connected(3).apply(to: store)
        store.noteRetriesSpent(true, source: source, serial: 2)
        _ = DaemonConnectionChange.disconnected("link lost").apply(to: store)
        #expect(!store.retriesSpent, "a stale park marked the next disconnect offline")
        // A park of a later attempt of the same connection still marks it.
        store.noteRetriesSpent(true, source: source, serial: 4)
        #expect(store.retriesSpent)
        // Another connection's serials are not comparable: its park marks the store.
        _ = connected(5).apply(to: store)
        _ = DaemonConnectionChange.disconnected("link lost").apply(to: store)
        store.noteRetriesSpent(true, source: UUID(), serial: 1)
        #expect(store.retriesSpent)
    }

    /// Review F2 (fc883e4): a new startup attempt armed the startup deadline, which a recovery inside the
    /// existing connection never cancelled, so a working machine later read as failed to start.
    @Test func reconnectOnADroppedDaemonWakesItWithNoNewStartupAttempt() {
        #expect(SSHConnectionMachine.Status.connected.reconnectStep(daemonConnected: true, daemonFailed: false, daemonDown: true) == .wake)
        #expect(SSHConnectionMachine.Status.connected.reconnectStep(daemonConnected: true, daemonFailed: true, daemonDown: true) == .reconnectDaemon)
        #expect(SSHConnectionMachine.Status.connected.reconnectStep(daemonConnected: true, daemonFailed: false) == .nothing)
        #expect(SSHConnectionMachine.Status.reconnecting.reconnectStep(daemonConnected: true, daemonFailed: false, daemonDown: true) == .wake)
        #expect(SSHConnectionMachine.Status.offline.reconnectStep(daemonConnected: true, daemonFailed: false, daemonDown: true) == .connect)
    }

    @Test func reconnectOnADroppedDaemonKeepsTheStartupBookkeeping() throws {
        let session = try Self.session()
        session.linkStatus = .connected
        session.daemon.store.connectionState = .disconnected("link lost")
        #expect(SidebarBridge.sshStatus(session, compatibility: nil) == .connecting)
        Self.service().reconnect(session)
        #expect(session.connectionAttemptID == 0, "a new startup attempt would arm a deadline no recovery cancels")
        #expect(session.daemon.startup == .connecting, "the startup state is left as it was")
        #expect(session.linkStatus == .connected, "the running link client is kept")
        session.close()
    }

    /// Review of 0f69ab8, F1: Reconnect on an established machine whose link was `.connecting` (its restart
    /// probe after an exit) fell through to a new startup attempt. The recovery came inside the existing
    /// connection, so no didConnect cancelled the deadline, and the working machine later read as failed.
    /// An established machine's Reconnect only wakes, whatever the link's status.
    @Test(.timeLimit(.minutes(1))) func reconnectDuringARestartProbeKeepsTheStartupBookkeeping() async throws {
        let log = "/private/tmp/cn-restart-probe-\(UUID().uuidString.prefix(8)).log"
        defer { try? FileManager.default.removeItem(atPath: log) }
        // Connection 0 drops 0.3 s after its handshake; later ones serve and stay.
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
                data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'restart-probe-%d' % nth, 'pid': 4242, 'capabilities': []}
            print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
            if frame.get('cmd') == 'subscribe' and nth == 0:
                time.sleep(0.3)
                sys.exit(0)
        """#
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, log])
        let socket = "/tmp/cn-restart-probe-\(UUID().uuidString.prefix(8)).sock"
        let calls = Mutex(0)
        let session = try Self.session()
        defer { session.close() }
        session.linkStatus = .connected
        session.daemon.startupDeadline = .seconds(1)
        // The startup deadline runs on a clock only the test moves.
        let clock = ManualClock()
        session.daemon.startupClock = clock
        session.daemon.start(remote: {
            let nth = calls.withLock { $0 += 1; return $0 }
            // The link exited; its restart probe takes a while, then the link runs again.
            if nth == 2 { try await Task.sleep(for: .milliseconds(1200)) }
            return socket
        }, bridge: bridge, requiredCapabilities: [], followsLink: true)
        let deadline = ContinuousClock.now + .seconds(15)
        while calls.withLock({ $0 }) < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(calls.withLock { $0 } == 2, "the drop's attempt (the restart probe) began")
        #expect(session.daemon.startup == .connected)
        // A person's Reconnect during the restart probe.
        session.linkStatus = .connecting
        Self.service().reconnect(session)
        #expect(session.connectionAttemptID == 0, "a new startup attempt would arm a deadline no recovery cancels")
        while !Self.recovered(session, log: log), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(Self.recovered(session, log: log), "recovered inside the existing connection")
        // Past the startup deadline: no false startup failure. The connection cancelled the deadline and
        // the recovery armed none, so nothing is asleep on its clock and no amount of time fails the start.
        #expect(clock.sleeperCount == 0, "a startup deadline is still pending after the recovery")
        clock.advance(by: .seconds(60))
        #expect(!session.daemon.startup.isUnavailable, "the recovered machine read as failed to start")
        #expect(session.daemonFailure == nil)
    }

    /// Review of 146f273, F1: a parked daemon (link connected, its reconnect failed and waits for an event)
    /// read as connecting, so a pane waited 45 s instead of reconnecting. It reads offline as on the base:
    /// using the machine reconnects it, and Reconnect wakes the parked connection.
    @Test(.timeLimit(.minutes(1))) func aParkedDaemonReadsOfflineAndUsingItReconnects() async throws {
        let log = "/private/tmp/cn-parked-\(UUID().uuidString.prefix(8)).log"
        defer { try? FileManager.default.removeItem(atPath: log) }
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
                data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'parked-%d' % nth, 'pid': 4242, 'capabilities': []}
            print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
            if frame.get('cmd') == 'subscribe' and nth == 0:
                time.sleep(0.3)
                sys.exit(0)
        """#
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, log])
        let socket = "/tmp/cn-parked-\(UUID().uuidString.prefix(8)).sock"
        let calls = Mutex(0), reachable = Mutex(true)
        let session = try Self.session()
        let service = Self.service(with: session)
        defer { session.close() }
        session.linkStatus = .connected
        session.daemon.start(remote: {
            calls.withLock { $0 += 1 }
            guard reachable.withLock({ $0 }) else { throw DaemonError.notConnected }
            return socket
        }, bridge: bridge, requiredCapabilities: [], followsLink: true)
        let deadline = ContinuousClock.now + .seconds(15)
        while session.daemon.startup != .connected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        // The daemon side stops answering: the drop's attempt fails and the connection parks.
        reachable.withLock { $0 = false }
        while !session.retriesSpent, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(session.retriesSpent, "the reconnect parked")
        #expect(SidebarBridge.sshStatus(session, compatibility: nil) == .offline)
        #expect(SidebarBridge.paneUse(session.machineID, in: service.machines) == .down, "using the machine must reconnect it")
        let parkedAt = calls.withLock { $0 }
        reachable.withLock { $0 = true }
        service.reconnect(session)
        while !Self.recovered(session, log: log), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(Self.recovered(session, log: log), "Reconnect woke the parked connection")
        #expect(calls.withLock { $0 } == parkedAt + 1)
        #expect(!session.retriesSpent)
        #expect(session.connectionAttemptID == 0, "no new startup attempt on an established machine")
    }

    @Test func anEstablishedMachinesReconnectOnlyWakesWhateverTheLinksStatus() {
        typealias S = SSHConnectionMachine.Status
        for status: S in [.connecting, .reconnecting, .failed("x"), .unreachable("x")] {
            #expect(status.reconnectStep(daemonConnected: false, daemonFailed: true, daemonDown: true, daemonEstablished: true) == .wake, "\(status)")
        }
        #expect(S.connected.reconnectStep(daemonConnected: true, daemonFailed: false, daemonDown: true, daemonEstablished: true) == .wake)
        #expect(S.connected.reconnectStep(daemonConnected: true, daemonFailed: false, daemonEstablished: true) == .nothing)
        #expect(S.connecting.reconnectStep(daemonConnected: false, daemonFailed: false) == .newAttempt, "no established connection: a new attempt")
    }

    private static func recovered(_ session: SSHMachineSession, log: String) -> Bool {
        let identifies = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").count
        guard identifies >= 2, case .connected = session.daemon.store.connectionState else { return false }
        return true
    }

    // MARK: G5

    @Test func onlyAPersonsRunIsAPersonsRequest() {
        #expect(ActionInvocation(origin: .user).isPersonsRequest)
        #expect(ActionInvocation(origin: .cli).isPersonsRequest)
        for origin: ActionOrigin in [.page, .mcp, .script, .remote] { #expect(!ActionInvocation(origin: origin).isPersonsRequest) }
    }

    @Test func aSessionInUseWaitsForAPerson() {
        var machine = SSHConnectionMachine()
        machine.handle(.connect)
        machine.handle(.failed(.sessionInUse("in use by another cmux daemon")))
        #expect(machine.waitsForUser)
        machine.handle(.wake(.appActivated))
        #expect(machine.waitsForUser)
        machine.handle(.attemptStarted)
        #expect(machine.waitsForUser, "An automatic attempt the gate turns away keeps it user-only")
        machine.handle(.wake(.networkChanged))
        #expect(!machine.mayAttempt)
        machine.handle(.wake(.user))
        #expect(!machine.waitsForUser)

        var other = SSHConnectionMachine()
        other.handle(.connect)
        other.handle(.failed(.remoteFailed("link closed during handshake")))
        #expect(!other.waitsForUser)
    }

    @Test func reconnectOnUseLeavesASessionInUseAndAPersonTakesItOver() async throws {
        let session = try Self.session()
        await session.link.handle(.connect)
        await session.link.handle(.failed(.sessionInUse("in use by another cmux daemon")))
        await session.link.handle(.attemptStarted)
        session.linkStatus = .failed("in use by another cmux daemon")
        #expect(session.waitsForUser)
        let service = Self.service(with: session)
        #expect(SidebarBridge.paneUse(session.machineID, in: service.machines) == .stuck)
        service.reconnect(session, byPerson: false)
        #expect(session.connectionAttemptID == 0, "Reconnect on use starts nothing")
        service.reconnect(session, byPerson: true)
        #expect(session.connectionAttemptID == 1, "A person's Reconnect takes it over")
        session.close()
    }
}
