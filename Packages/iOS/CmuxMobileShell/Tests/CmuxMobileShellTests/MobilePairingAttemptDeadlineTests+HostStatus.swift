import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
extension MobilePairingAttemptDeadlineTests {
    @Test func hostStatusUsesOnlyTheRemainingPairingAttemptBudget() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        await router.setWorkspaceListResponseHook {
            clock.advance(by: 2)
        }
        var runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now }
        )
        runtime.pairingAttemptTimeoutNanoseconds = 1_000_000_000
        let store = makeStore(runtime: runtime)

        let result = await store.connectPairingURLResult(
            try attachURL(for: makeTicket(clock: clock))
        )

        #expect(result == .failed)
        #expect(await router.count(of: "workspace.list") == 1)
        #expect(await router.count(of: "mobile.host.status") == 0)
        #expect(store.connectionState == .disconnected)
    }
}
