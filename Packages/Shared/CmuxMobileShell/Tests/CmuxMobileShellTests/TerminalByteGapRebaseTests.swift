import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func byteGapDeliversLiveChunkAndRequestsSingleReplay() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing byte-gap delivery"
    )
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(surfaceID: surfaceID, seq: 0, text: "abc"))
    let firstDelivered = try await pollUntil { collector.lines.contains("abc") }
    #expect(firstDelivered)

    await transport.deliver(try terminalBytesEventFrame(surfaceID: surfaceID, seq: 10, text: "gap"))
    let gapDelivered = try await pollUntil { collector.lines.contains("gap") }
    #expect(gapDelivered)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)
    let replayCountAfterGap = await router.count(of: "mobile.terminal.replay")

    await transport.deliver(try terminalBytesEventFrame(surfaceID: surfaceID, seq: 13, text: "!"))
    let nextDelivered = try await pollUntil { collector.lines.contains("!") }
    #expect(nextDelivered)
    let extraReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterGap + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!extraReplayRequested)
    collector.unmount()
}

@MainActor
@Test func byteGapCancelsInFlightReplayAndRequestsFreshRepair() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing byte-gap replay replacement"
    )
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    let transport = try #require(box.get())

    await transport.deliver(try terminalBytesEventFrame(surfaceID: surfaceID, seq: 0, text: "abc"))
    let firstDelivered = try await pollUntil { collector.lines.contains("abc") }
    #expect(firstDelivered)

    await router.holdNextReplayResponses()
    store.requestTerminalReplay(surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)
    #expect(store.terminalReplaySurfaceIDsInFlight.contains(surfaceID))

    await transport.deliver(try terminalBytesEventFrame(surfaceID: surfaceID, seq: 10, text: "gap"))
    let gapDelivered = try await pollUntil { collector.lines.contains("gap") }
    #expect(gapDelivered)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 2)

    let replayCountAfterGap = await router.count(of: "mobile.terminal.replay")
    let extraReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterGap + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!extraReplayRequested)

    await router.releaseAllHeld()
    collector.unmount()
}
