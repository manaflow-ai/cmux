@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Testing

/// HQ #4877 G4 and G5: an SSH machine whose later reconnect spent its retries reads Offline with
/// a Reconnect that starts a fresh connect, never Connecting forever; and reconnect on use never
/// takes over a session another cmux daemon holds, which only a person's Reconnect may.
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

    @Test func reconnectAfterSpentRetriesIsAFreshConnect() {
        for link: SSHConnectionMachine.Status in [.connecting, .connected, .reconnecting] {
            #expect(link.reconnectStep(daemonConnected: true, daemonFailed: false, retriesSpent: true) == .restart)
        }
        #expect(SSHConnectionMachine.Status.offline.reconnectStep(daemonConnected: true, daemonFailed: false, retriesSpent: true) == .connect)
        #expect(SSHConnectionMachine.Status.connected.reconnectStep(daemonConnected: true, daemonFailed: false) == .nothing)
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

    @Test func reconnectOnASpentSessionStartsANewAttemptAndClearsTheMark() throws {
        let session = try Self.session()
        session.linkStatus = .connected
        session.daemon.store.connectionState = .disconnected("link lost")
        session.daemon.store.noteRetriesSpent(true)
        #expect(SidebarBridge.sshStatus(session, compatibility: nil) == .offline)
        Self.service().reconnect(session)
        #expect(session.connectionAttemptID == 1)
        #expect(!session.retriesSpent)
        #expect(session.linkStatus == .connecting)
        session.close()
    }

    @Test func aRestartedSessionThatClosesNeverConnectsAgain() async throws {
        let session = try Self.session()
        session.linkStatus = .connected
        session.daemon.store.noteRetriesSpent(true)
        Self.service().reconnect(session)
        session.close()
        for _ in 0..<40 { await Task.yield() }
        #expect(session.linkStatus == .offline, "The restart's connect was cancelled by close()")
        #expect(session.connectionAttemptID == 1)
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
