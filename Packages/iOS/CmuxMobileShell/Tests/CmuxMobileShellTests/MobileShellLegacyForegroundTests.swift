import Testing
@testable import CmuxMobileShell

@MainActor
@Test func foregroundResumeLegacySubscribeAckReplaysMountedSurfaces() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.omitAlreadySubscribedField()
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
        "the cold replay response must settle before testing legacy foreground resume"
    )

    store.setAppForegroundActive(false)
    store.resumeForegroundRefresh()
    let reasserted = try await pollUntil {
        await router.count(of: "mobile.events.subscribe") >= 2
    }
    #expect(reasserted, "foreground resume should reassert the existing subscription")
    let pinged = try await pollUntil {
        await router.count(of: "mobile.events.ping") >= 1
    }
    #expect(pinged, "legacy foreground resume must still prove the push stream before trusting it")
    let replayed = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= 2
    }
    #expect(
        replayed,
        "legacy hosts omit already_subscribed, so foreground resume must replay mounted surfaces to catch up missed terminal frames"
    )
    #expect(
        await router.count(of: "mobile.host.status") == 1,
        "legacy foreground catch-up must not restart the listener"
    )
    collector.unmount()
}
