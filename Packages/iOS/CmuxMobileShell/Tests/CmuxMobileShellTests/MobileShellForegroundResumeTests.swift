import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func shortHealthyForegroundResumeDoesNotReplayMountedSurfaces() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing foreground resume"
    )
    let replayCount = await router.count(of: "mobile.terminal.replay")
    let subscribeCount = await router.count(of: "mobile.events.subscribe")

    store.suspendForegroundRefresh()
    clock.advance(by: 5)
    store.resumeForegroundRefresh()

    let replayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCount + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!replayRequested)
    let resubscribed = await router.waitForCount(
        of: "mobile.events.subscribe",
        atLeast: subscribeCount + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!resubscribed)
    collector.unmount()
}

@MainActor
@Test func longForegroundResumeStillReplaysMountedSurfaces() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing long foreground resume"
    )
    let subscribeCount = await router.count(of: "mobile.events.subscribe")

    store.suspendForegroundRefresh()
    clock.advance(by: 31)
    store.resumeForegroundRefresh()

    await router.waitForCount(of: "mobile.events.subscribe", atLeast: subscribeCount + 1)
    collector.unmount()
}
