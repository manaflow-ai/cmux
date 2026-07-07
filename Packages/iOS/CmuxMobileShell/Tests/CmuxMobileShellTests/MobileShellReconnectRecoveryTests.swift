import CmuxMobileRPC
import Testing
@testable import CmuxMobileShell

/// When a liveness probe times out on a reconnectable saved Mac, recovery must
/// replace the persistent RPC client. Restarting only the event listener keeps
/// sending through the same half-dead transport, which is why the iOS app felt
/// permanently broken until process restart.
@MainActor
@Test func failedLivenessProbeReconnectsSavedMacWithFreshClient() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeReconnectableConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let sawInitialSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawInitialSubscribe, "listener must establish the initial push subscription")

    await router.holdSubscribeRequest(number: 2)
    clock.advance(by: 10)
    store.debugRunRenderGridLivenessCheckForTesting()

    let reconnected = try await pollUntil(attempts: 800) {
        await router.count(of: "workspace.list") >= 2 && store.macConnectionStatus == .connected
    }
    #expect(
        reconnected,
        "a failed liveness probe must reconnect from the saved Mac record instead of reusing the stale RPC client"
    )
    #expect(store.connectionState == .connected)
}

/// Once an RPC failure has marked the logical connection unavailable, a later
/// path-change recovery must trust that health status and rebuild the stored Mac
/// connection. Re-subscribing on the old client can keep a wedged iOS transport
/// alive forever.
@MainActor
@Test func networkChangeAfterUnavailableStatusReconnectsSavedMacWithFreshClient() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let reachability = ManualReachability()
    let store = try await makeReconnectableConnectedStore(
        router: router,
        box: box,
        clock: clock,
        reachability: reachability
    )
    defer {
        Task { await router.releaseAllHeld() }
    }

    let sawInitialSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawInitialSubscribe, "listener must establish the initial push subscription")
    store.startObservingNetworkPathChanges()
    let observingNetwork = try await pollUntil { reachability.hasSubscriber }
    #expect(observingNetwork, "connected stores must observe reachability changes")

    store.markMacConnectionUnavailableIfNeeded(after: MobileShellConnectionError.requestTimedOut)
    #expect(store.connectionState == .connected)
    #expect(store.macConnectionStatus == .unavailable)

    await router.holdSubscribeRequest(number: 2)
    reachability.emitPathChange()

    let reconnected = try await pollUntil(attempts: 800) {
        await router.count(of: "workspace.list") >= 2 && store.macConnectionStatus == .connected
    }
    #expect(
        reconnected,
        "network recovery must reconnect from the saved Mac when macConnectionStatus has already declared the current client unavailable"
    )
}
