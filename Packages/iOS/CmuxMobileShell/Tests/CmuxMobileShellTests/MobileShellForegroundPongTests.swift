import Foundation
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

@MainActor
@Test func foregroundResumeWithoutEventPingCapabilityRestartsWithoutCallingPing() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.bytes.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
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
        "the cold replay response must settle before testing mixed-version foreground resume"
    )

    store.setAppForegroundActive(false)
    store.resumeForegroundRefresh()
    let reasserted = try await pollUntil {
        await router.count(of: "mobile.events.subscribe") >= 2
    }
    #expect(reasserted, "foreground resume should still reassert older Mac subscriptions")
    let pinged = try await pollUntil(attempts: 30) {
        await router.count(of: "mobile.events.ping") >= 1
    }
    #expect(pinged == false, "older Macs without terminal.event_ping.v1 must not receive mobile.events.ping")
    let restarted = try await pollUntil(attempts: 600) {
        await router.count(of: "mobile.host.status") >= 2
    }
    #expect(
        restarted,
        "without event-ping proof, an older Mac's already-subscribed ack must use the legacy foreground restart path"
    )
    collector.unmount()
}

@MainActor
@Test func foregroundSubscribeTimeoutDoesNotRestartAfterAppBackgroundsAgain() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let sawSubscribe = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(sawSubscribe, "listener must establish the push subscription")

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink arms exactly one cold-attach replay")
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing subscribe timeout cancellation"
    )

    await router.holdSubscribeRequest(number: 2)
    store.setAppForegroundActive(false)
    store.resumeForegroundRefresh()
    let reasserted = try await pollUntil {
        await router.count(of: "mobile.events.subscribe") >= 2
    }
    #expect(reasserted, "foreground resume should send a bounded subscription reassertion")
    store.setAppForegroundActive(false)
    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(
        await router.count(of: "mobile.host.status") == 1,
        "a subscribe timeout after the app backgrounds again must not restart the listener"
    )
    collector.unmount()
}

@MainActor
@Test func foregroundActivityRequiresAllScenesInactive() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let firstScene = UUID()
    let secondScene = UUID()
    #expect(store.setSceneForegroundActive(true, sceneID: firstScene))
    #expect(store.setSceneForegroundActive(true, sceneID: secondScene) == false)
    store.setSceneForegroundActive(false, sceneID: firstScene)
    #expect(store.isAppForegroundActive, "one inactive scene must not background the shared shell store")
    store.setSceneForegroundActive(false, sceneID: secondScene)
    #expect(store.isAppForegroundActive == false, "the shell store becomes inactive only after every scene is inactive")
}
