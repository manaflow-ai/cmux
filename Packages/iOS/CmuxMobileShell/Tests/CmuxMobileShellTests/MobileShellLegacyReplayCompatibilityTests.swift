import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func legacyHostResyncDoesNotBlockLiveOutputBehindReplayBarrier() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let coldReplayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= 1
    }
    #expect(coldReplayRequested)
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the legacy cold replay must settle before testing resync"
    )

    let transport = try #require(box.get())
    let liveFrame = try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 100,
        text: "legacy-live"
    )
    let replayCount = await router.count(of: "mobile.terminal.replay")
    await router.holdNextReplayResponses()
    store.requestTerminalResync(surfaceID: "live-terminal", deferBehindActiveReplay: true)
    let resyncRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCount
    }
    #expect(resyncRequested)

    await transport.deliver(liveFrame)
    let liveOutputDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("legacy-live") }
    }
    #expect(
        liveOutputDelivered,
        "a host without terminal.replay.v1 must keep delivering live output while its unbarriered resync is pending"
    )

    await router.releaseAllHeld()
    collector.unmount()
}
