@testable import CmuxNextApp
import Testing

@Suite struct RemoteConnectRecoveryTests {
    @Test func aLoadedConnectionCanBeHandledWithoutAnExistingWindow() {
        #expect(RemoteHandlers.shouldHandleConnectionObservation(loaded: true, hasWindow: false))
    }
}
