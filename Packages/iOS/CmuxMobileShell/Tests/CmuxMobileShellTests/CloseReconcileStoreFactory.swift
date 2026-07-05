import CMUXMobileCore
import Testing
@testable import CmuxMobileShell

@MainActor
struct CloseReconcileStoreFactory {
    let router: CloseReconcileHostRouter
    let clock: TestClock

    func makeConnectedStore() async throws -> MobileShellComposite {
        let runtime = LivenessTestRuntime(
            transportFactory: CloseReconcileTransportFactory(router: router),
            now: { clock.now }
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        let ticket = try makeTicket(clock: clock)
        let connected = await store.connectPairingURL(try attachURL(for: ticket))
        #expect(connected, "scripted connect must succeed")
        return store
    }
}
