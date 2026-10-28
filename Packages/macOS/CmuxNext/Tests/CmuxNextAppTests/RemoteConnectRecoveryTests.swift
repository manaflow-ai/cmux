@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextRemote
import Testing

@Suite struct RemoteConnectRecoveryTests {
    @Test func aConnectingObservationStaysAliveWithoutAnExistingWindow() {
        #expect(!RemoteHandlers.shouldEndConnectionObservation(status: .connecting))
    }

    @Test func aDaemonFailureClearsRetrySuppression() {
        #expect(RemoteHandlers.shouldClearRetrySuppression(for: "daemon handshake failed"))
    }

    @Test func aRetryChangesTheDaemonObservationForAnIdenticalFailure() {
        let failure = DaemonStartupState.unavailable(.timedOut("daemon handshake"))
        let first = SSHMachineSession.daemonObservationKey(startup: failure, recoveryAttempt: 0)
        let retry = SSHMachineSession.daemonObservationKey(startup: failure, recoveryAttempt: 1)
        #expect(first != retry)
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
