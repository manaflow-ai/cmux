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

    /// The link is the only layer that redials (cmuxterm-hq#7766): a later drop reads as the link
    /// says, and Reconnect retries the daemon connection over the same link client instead of
    /// killing and restarting it.
    @Test func aLaterDropReadsAsTheLinkSays() {
        #expect(SSHConnectionMachine.Status.reconnecting.sidebarStatus(startupFailed: false, daemonConnected: false, compatibility: nil) == .reconnecting)
        #expect(SSHConnectionMachine.Status.connecting.sidebarStatus(startupFailed: false, daemonConnected: false, compatibility: nil) == .connecting)
        #expect(SSHConnectionMachine.Status.connected.sidebarStatus(startupFailed: true, daemonConnected: false, compatibility: nil) == .failed,
                "A startup failure keeps its own word")
        #expect(MachineLinkState.reconnectsOnUse(.offline), "Using the machine reconnects it")
    }

    @Test func reconnectOnADroppedDaemonRetriesItOverTheSameLink() {
        #expect(SSHConnectionMachine.Status.connected.reconnectStep(daemonConnected: true, daemonFailed: false, daemonDown: true) == .reconnectDaemon)
        #expect(SSHConnectionMachine.Status.connected.reconnectStep(daemonConnected: true, daemonFailed: false) == .nothing)
        #expect(SSHConnectionMachine.Status.reconnecting.reconnectStep(daemonConnected: true, daemonFailed: false, daemonDown: true) == .wake)
        #expect(SSHConnectionMachine.Status.offline.reconnectStep(daemonConnected: true, daemonFailed: false, daemonDown: true) == .connect)
    }

    @Test func reconnectOnADroppedDaemonStartsANewAttemptOnTheLiveLink() throws {
        let session = try Self.session()
        session.linkStatus = .connected
        session.daemon.store.connectionState = .disconnected("link lost")
        #expect(SidebarBridge.sshStatus(session, compatibility: nil) == .connecting)
        Self.service().reconnect(session)
        #expect(session.connectionAttemptID == 1)
        #expect(session.linkStatus == .connected, "the running link client is kept")
        session.close()
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
