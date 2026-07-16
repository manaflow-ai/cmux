import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct ManualHostTrustExpirationSchedulingTests {
    @Test func repeatedHealthSchedulingKeepsOneExpirationLookup() async throws {
        let router = LivenessHostRouter()
        let trustStore = CountingExpirationManualHostTrustStore()
        let clock = TestClock()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: TransportBox()),
            now: { clock.now },
            supportedRouteKinds: [.manualHost],
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite(
            runtime: runtime,
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: AlwaysOnlineReachability(),
            manualHostTrustStore: trustStore
        )
        store.signIn()

        let queued = await store.connectManualHost(
            name: "Studio Mac",
            host: "192.168.1.77",
            port: 58_465
        )
        let connected = await store.acceptManualHostTrustWarning()
        let armed = try await pollUntil {
            await trustStore.expirationQueryCount() >= 1
        }

        #expect(queued == .needsUserApproval)
        #expect(connected == .connected)
        #expect(armed)
        let initialQueries = await trustStore.expirationQueryCount()

        for _ in 0..<20 {
            store.scheduleManualHostTrustExpirationForActiveRoute()
        }
        let rearmed = try await pollUntil(attempts: 30) {
            await trustStore.expirationQueryCount() > initialQueries
        }

        #expect(!rearmed)
    }
}
