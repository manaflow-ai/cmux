@testable import CmuxNextApp
import CmuxNextActions
@testable import CmuxNextDaemonService
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing

@Suite struct RemoteConnectRecoveryTests {
    @Test func aConnectingObservationStaysAliveWithoutAnExistingWindow() {
        #expect(!RemoteHandlers.shouldEndConnectionObservation(status: .connecting))
    }

    @Test func aWindowlessNoHostFailureRequestsARecoveryWindow() {
        let failure = SSHMachineSession.DaemonFailure(attemptID: 1, error: "Could not resolve hostname nohost.invalid")
        #expect(RemoteHandlers.shouldOpenRecoveryWindow(loaded: false, hasWindow: false,
                                                        status: .connecting, failure: failure,
                                                        currentAttemptID: 1))
    }

    @Test @MainActor func retryFromUnavailableStartsANewAttemptBeforeWakingTheDaemon() throws {
        let host = try SSHHost(destination: SSHDestination(parsing: "nohost.invalid"))
        let session = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                        paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/remote-recovery-tests")),
                                        environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        session.daemon.noteStartupFailure(.timedOut("old daemon failure"))
        session.daemonFailure = .init(attemptID: 1, error: "old daemon failure")
        let service = SSHService(machines: MachineRegistry(local: DaemonService()), bundleID: nil,
                                 mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        service.reconnect(session)
        #expect(session.connectionAttemptID == 1)
        #expect(session.daemon.startup == .connecting)
        #expect(session.daemonFailure == nil)
    }

    /// Retry from a blocked link failure stamps a new attempt synchronously, but the link only
    /// leaves its failure after an asynchronous `wake(.user)`. The mirrored status must not
    /// carry the previous attempt's failure into the new one, or the recovery observer reopens
    /// the stale sheet and keeps it over the real result of the retry.
    @Test(arguments: [SSHConnectionMachine.Status.authFailed("Permission denied (publickey)"),
                      .hostKeyUntrusted("REMOTE HOST IDENTIFICATION HAS CHANGED"),
                      .installFailed("download failed")])
    @MainActor func retryFromABlockedLinkFailureDoesNotReplayItForTheNewAttempt(
        _ failure: SSHConnectionMachine.Status
    ) throws {
        let host = try SSHHost(destination: SSHDestination(parsing: "nohost.invalid"))
        let session = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                        paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/remote-recovery-tests")),
                                        environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        session.linkStatus = failure
        let service = SSHService(machines: MachineRegistry(local: DaemonService()), bundleID: nil,
                                 mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        service.reconnect(session)
        #expect(session.connectionAttemptID == 1)
        #expect(!session.linkStatus.needsRecovery)
        #expect(!RemoteHandlers.shouldOpenRecoveryWindow(loaded: false, hasWindow: false,
                                                         status: session.linkStatus, failure: session.daemonFailure,
                                                         currentAttemptID: session.connectionAttemptID))
    }

    @Test @MainActor func reconnectOnAHealthyConnectedLinkDoesNotStartARecoveryAttempt() throws {
        let host = try SSHHost(destination: SSHDestination(parsing: "nohost.invalid"))
        let session = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                        paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/remote-recovery-tests")),
                                        environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        session.linkStatus = .connected
        session.daemon.noteStartupFailure(.binaryNotFound(searched: ["/usr/bin/false"]))
        let service = SSHService(machines: MachineRegistry(local: DaemonService()), bundleID: nil,
                                 mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        service.reconnect(session)
        #expect(session.connectionAttemptID == 0)
        #expect(session.daemon.startup.isUnavailable)
    }

    @Test func reconnectDuringATransientInterruptionKeepsAnEstablishedDaemonsStartup() {
        #expect(SSHConnectionMachine.Status.reconnecting.reconnectStep(daemonConnected: true, daemonFailed: false) == .wake)
        #expect(SSHConnectionMachine.Status.reconnecting.reconnectStep(daemonConnected: false, daemonFailed: false) == .newAttempt)
        #expect(SSHConnectionMachine.Status.connected.reconnectStep(daemonConnected: true, daemonFailed: false) == .nothing)
        #expect(SSHConnectionMachine.Status.offline.reconnectStep(daemonConnected: true, daemonFailed: false) == .connect)
    }

    @Test func aRetryChangesTheDaemonObservationForAnIdenticalFailure() {
        let failure = DaemonStartupState.unavailable(.timedOut("daemon handshake"))
        let first = SSHMachineSession.daemonObservationKey(startup: failure, attemptID: 1)
        let retry = SSHMachineSession.daemonObservationKey(startup: failure, attemptID: 2)
        #expect(first != retry)
    }

    @Test func anIdenticalDaemonErrorOnANewAttemptIsARecoveryFailure() {
        let first = SSHMachineSession.DaemonFailure(attemptID: 1, error: "same daemon error")
        let retry = SSHMachineSession.DaemonFailure(attemptID: 2, error: "same daemon error")
        #expect(first != retry)
        #expect(RemoteHandlers.shouldPresentDaemonFailure(retry, currentAttemptID: 2))
    }

    @Test func remoteGroupMarkingSurvivesRecoverableLinkFailures() {
        #expect(RemoteGroupHandlers.shouldContinueMarking(status: .authFailed("denied")))
        #expect(RemoteGroupHandlers.shouldContinueMarking(status: .hostKeyUntrusted("changed")))
        #expect(RemoteGroupHandlers.shouldContinueMarking(status: .installFailed("download")))
        #expect(!RemoteGroupHandlers.shouldContinueMarking(status: .offline))
    }

    @MainActor @Test func newGroupFocusRequestEnablesInteractiveFlowDuringCapture() {
        let invocation = ActionInvocation(arguments: ["focus": .bool(true)], origin: .cli)
        #expect(RemoteGroupHandlers.shouldOfferInteractiveFlow(invocation))
    }
}
