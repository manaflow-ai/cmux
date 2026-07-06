import Testing
@testable import CmuxMobileShell

/// A foreground subscribe ack is only control-plane proof: if the matching
/// pong event never reaches the listener's `AsyncStream`, the push stream is
/// not safe to reuse and must be restarted immediately.
@MainActor
@Test func foregroundResumeRestartsWhenPongDoesNotReachEventStream() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink arms exactly one cold-attach replay")
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing foreground stream proof"
    )

    await router.setDropPongEvents(true)
    store.setAppForegroundActive(false)
    store.resumeForegroundRefresh()

    let pinged = try await pollUntil {
        await router.count(of: "mobile.events.ping") >= 1
    }
    #expect(pinged, "foreground resume should send a push-stream ping after the subscribe ack")
    let restarted = try await pollUntil(attempts: 600) {
        await router.count(of: "mobile.host.status") >= 2
    }
    #expect(
        restarted,
        "a foreground ping whose pong never reaches the event stream must restart the listener"
    )
    let replayed = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= 2
    }
    #expect(replayed, "foreground stream restart must replay mounted terminal surfaces")
    collector.unmount()
}

@MainActor
@Test func foregroundPongTimeoutDoesNotRestartAfterAppBackgroundsAgain() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink arms exactly one cold-attach replay")
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing background cancellation"
    )

    await router.setDropPongEvents(true)
    store.setAppForegroundActive(false)
    store.resumeForegroundRefresh()
    let pinged = try await pollUntil {
        await router.count(of: "mobile.events.ping") >= 1
    }
    #expect(pinged, "foreground resume should send a push-stream ping")
    store.setAppForegroundActive(false)
    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(
        await router.count(of: "mobile.host.status") == 1,
        "a pong timeout after the app backgrounds again must not restart the listener"
    )
    collector.unmount()
}
