import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

/// The watchdog's original purpose (the ~85s silent-death hang) must keep
/// working: silence past the threshold plus a host that stops answering the
/// probe must still tear down and re-subscribe on a fresh transport.
@MainActor
@Test func watchdogStillResubscribesGenuinelyDeadStream() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")
    let hostStatusCountBeforeFailure = await router.count(of: "mobile.host.status")

    // Model a dead push path after the request has already left the phone.
    await router.holdSubscribeRequest(number: 2)
    clock.advance(by: 10)
    store.debugRunRenderGridLivenessCheckForTesting()

    let restarted = try await pollUntil(attempts: 600) {
        await router.count(of: "mobile.host.status") > hostStatusCountBeforeFailure
    }
    #expect(
        restarted,
        "a silent stream whose host stops answering the subscription probe must restart"
    )
    #expect(
        box.createdTransportCount() == 2,
        "a failed positive-liveness probe must rotate the stale transport"
    )
    await router.releaseAllHeld()
}

/// Retry is a session recovery action, not just a new subscription on the old
/// socket. The route/ticket/store stay mounted while the transport is replaced.
@MainActor
@Test func manualRetryRotatesPersistentTransportAndResubscribes() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let hostStatusCount = await router.count(of: "mobile.host.status")
    let subscribeCount = await router.count(of: "mobile.events.subscribe")

    store.retryMobileConnection()

    #expect(await router.waitForCount(
        of: "mobile.host.status",
        atLeast: hostStatusCount + 1
    ))
    #expect(await router.waitForCount(
        of: "mobile.events.subscribe",
        atLeast: subscribeCount + 1
    ))
    #expect(box.createdTransportCount() == 2)
    #expect(store.connectionState == .connected)
}

/// A transport-level request failure should enter automatic recovery instead
/// of immediately presenting the manual Retry state from issue #8005.
@MainActor
@Test func availabilityFailureAutomaticallyRotatesPersistentTransport() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let hostStatusCount = await router.count(of: "mobile.host.status")

    store.recoverMacConnectionIfNeeded(
        after: MobileShellConnectionError.requestTimedOut
    )
    #expect(box.createdTransportCount() == 1)
    #expect(store.macConnectionStatus == .connected)

    store.recoverMacConnectionIfNeeded(
        after: MobileShellConnectionError.transportWriteTimedOut
    )

    #expect(await router.waitForCount(
        of: "mobile.host.status",
        atLeast: hostStatusCount + 1
    ))
    #expect(box.createdTransportCount() == 2)
    #expect(!store.connectionRecoveryFailed)
    #expect(store.macConnectionStatus != .unavailable)
}

/// Recovery triggers share one owner, so a path transition or Retry arriving
/// behind a failed liveness verdict cannot rotate the replacement again.
@MainActor
@Test func concurrentRecoveryTriggersRotateTransportOnce() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let hostStatusCount = await router.count(of: "mobile.host.status")

    store.recoverMobileConnection(trigger: .liveness)
    store.recoverMobileConnection(trigger: .networkChange)

    #expect(await router.waitForCount(
        of: "mobile.host.status",
        atLeast: hostStatusCount + 1
    ))
    #expect(box.createdTransportCount() == 2)
}
