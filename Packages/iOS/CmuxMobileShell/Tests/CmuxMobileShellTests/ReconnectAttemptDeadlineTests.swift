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
    @Test func deadlineRaceReturnsNilWhenOperationIgnoresCancellation() async {
        // The race must not structurally await the losing side: an operation
        // that never completes AND ignores cancellation (the wedged-FFI-dial
        // shape) must still let the deadline resolve the race.
        let outcome = await MobileShellComposite.raceAgainstDeadline(
            nanoseconds: 50_000_000
        ) {
            await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in
                // Parked forever; no cancellation handler on purpose.
            }
        }
        #expect(outcome.value == nil)
        #expect(outcome.abandoned != nil, "the wedged operation is handed back for bounded tracking")
    }

    @Test func deadlineRaceReturnsOperationValueWhenItWins() async {
        let outcome = await MobileShellComposite.raceAgainstDeadline(
            nanoseconds: 5_000_000_000
        ) { 42 }
        #expect(outcome.value == 42)
        #expect(outcome.abandoned == nil)
    }

    @Test func userRetrySupersedesAttemptWhoseRestoringDeadlineElapsed() async throws {
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let runtime = LivenessTestRuntime(
            transportFactory: factory,
            now: Date.init,
            supportedRouteKinds: [.iroh]
        )
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": []],
            blockedTeams: [""]
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "reconnect-deadline-retry-\(UUID().uuidString)"
            )!
        )
        store.storedMacReconnectRestoringDeadlineSeconds = 0.15

        let firstAttempt = Task {
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        await pairedStore.waitUntilLoadStarted(teamID: nil)
        let deadlineElapsed = try await pollUntil(attempts: 1000) {
            store.didFinishStoredMacReconnectAttempt && !store.isReconnectingStoredMac
        }
        #expect(deadlineElapsed)

        let firstGeneration = store.storedMacReconnectGeneration
        store.storedMacReconnectRestoringDeadlineSeconds = 5
        let retry = Task {
            await store.retryActiveMacReconnect(stackUserID: "user-1")
        }
        var retryOwnsFlags = false
        for _ in 0..<1000 {
            let loadCount = await pairedStore.currentLoadAllCount()
            if store.storedMacReconnectGeneration > firstGeneration,
               store.isReconnectingStoredMac,
               loadCount >= 2 {
                retryOwnsFlags = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(retryOwnsFlags)

        await pairedStore.release(teamID: nil)
        #expect(await firstAttempt.value == false)
        #expect(store.storedMacReconnectGeneration > firstGeneration)
        #expect(store.isReconnectingStoredMac)

        await pairedStore.release(teamID: nil)
        #expect(await retry.value == false)
        #expect(!store.isReconnectingStoredMac)
    }

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

        // Starvation-proof windows: under full-suite parallel load the
        // recovery task may take seconds just to be scheduled (the suite is
        // timing-flaky on loaded machines even on main). Generous polls cost
        // time only on real failure.
        let dialed = try await pollUntil(attempts: 3000) {
            factory.attemptedKinds().count > dialsBeforeDrop
        }
        #expect(dialed, "the hung dial itself was attempted")
        // Pre-fix: the attempt never settles, isRedialingOrValidating stays
        // true forever, and this poll times out. Post-fix: the deadline
        // abandons the hung dial and settles the attempt as failed.
        let settled = try await pollUntil(attempts: 3000) {
            !store.connectionRecoveryOwner.isRedialingOrValidating
        }
        #expect(settled, "a hung dial must settle at the attempt deadline, not hold recovery forever")
        #expect(store.connectionState != .connected)

        // The timed-out attempt must feed the automatic retry loop: transient
        // backoff is recorded for the account the attempt dialed for.
        #expect(store.automaticIrohReconnectIsBlocked(accountID: "user-1"))

        // And the machine is unfrozen: a manual retry (hang lifted, modeling
        // the network recovering) dials fresh and connects. Release the
        // parked dials so abandoned attempts unwind the way real dials
        // eventually do; an eternal hang is a test artifact that races the
        // auto-retry loop's leftover state.
        factory.setHangingKinds([])
        await factory.releaseHangingTransports()
        let dialsBeforeManual = factory.attemptedKinds().count
        await store.reconnectOrRefresh()
        // Generous window: this tail runs under full-suite parallel load and
        // the manual path awaits several real round-trips.
        let reconnected = try await pollUntil(attempts: 3000) {
            store.connectionState == .connected
        }
        #expect(reconnected, "manual retry after a settled deadline must reconnect")
        #expect(factory.attemptedKinds().count > dialsBeforeManual)
    }
}
