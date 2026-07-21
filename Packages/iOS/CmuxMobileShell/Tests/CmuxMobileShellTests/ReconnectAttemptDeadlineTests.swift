import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/8531's
// wedge half: a redial whose transport dial hangs forever (relay DNS churn,
// hole-punch stall) must not hold the recovery owner's in-flight claim
// indefinitely. The attempt has a hard deadline; at expiry it settles as a
// timed-out failure, transient backoff is recorded, and the recovery machine
// accepts new triggers (manual retry succeeds immediately).
@MainActor
extension ReconnectRouteSelectionTests {
    @Test func hungRedialSettlesAtDeadlineAndUnfreezesRecovery() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        var runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: { clock.now },
            supportedRouteKinds: [.iroh]
        )
        // Small enough that the test settles fast; the production default is 30s.
        runtime.reconnectAttemptDeadlineNanoseconds = 150_000_000
        let store = try await makeReconnectStore(
            routes: [try iroh()],
            runtime: runtime
        )

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.connectionState == .connected)
        let client = try #require(store.remoteClient)

        // Every dial from here on parks forever, exactly like the observed
        // wedged Iroh dial.
        factory.setHangingKinds([.iroh])
        let dialsBeforeDrop = factory.attemptedKinds().count

        store.recoverDeadConnection(trigger: .eventStreamEnded, expectedClient: client)

        // Pre-fix: the attempt never settles, isRedialingOrValidating stays
        // true forever, and this poll times out. Post-fix: the deadline
        // abandons the hung dial and settles the attempt as failed.
        let settled = try await pollUntil {
            !store.connectionRecoveryOwner.isRedialingOrValidating
        }
        #expect(settled, "a hung dial must settle at the attempt deadline, not hold recovery forever")
        #expect(factory.attemptedKinds().count > dialsBeforeDrop, "the hung dial itself was attempted")
        #expect(store.connectionState != .connected)

        // The timed-out attempt must feed the automatic retry loop: transient
        // backoff is recorded for the account the attempt dialed for.
        #expect(store.automaticIrohReconnectIsBlocked(accountID: "user-1"))

        // And the machine is unfrozen: a manual retry (hang lifted, modeling
        // the network recovering) dials fresh and connects.
        factory.setHangingKinds([])
        let dialsBeforeManual = factory.attemptedKinds().count
        await store.reconnectOrRefresh()
        let reconnected = try await pollUntil {
            store.connectionState == .connected
        }
        #expect(reconnected, "manual retry after a settled deadline must reconnect")
        #expect(factory.attemptedKinds().count > dialsBeforeManual)
    }
}
