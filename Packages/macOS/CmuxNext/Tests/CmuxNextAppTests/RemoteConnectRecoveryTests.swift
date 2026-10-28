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

    @MainActor @Test func newGroupFocusRequestEnablesInteractiveFlowDuringCapture() {
        let invocation = ActionInvocation(arguments: ["focus": .bool(true)], origin: .cli)
        #expect(RemoteGroupHandlers.shouldOfferInteractiveFlow(invocation))
    }
}
