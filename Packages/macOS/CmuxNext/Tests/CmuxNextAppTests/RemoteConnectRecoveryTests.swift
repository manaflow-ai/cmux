@testable import CmuxNextApp
import CmuxNextActions
import Testing

@Suite struct RemoteConnectRecoveryTests {
    @Test func aLoadedConnectionCanBeHandledWithoutAnExistingWindow() {
        #expect(RemoteHandlers.shouldHandleConnectionObservation(loaded: true, hasWindow: false))
    }

    @MainActor @Test func newGroupFocusRequestEnablesInteractiveFlowDuringCapture() {
        let invocation = ActionInvocation(arguments: ["focus": .bool(true)], origin: .cli)
        #expect(RemoteGroupHandlers.shouldOfferInteractiveFlow(invocation))
    }
}
