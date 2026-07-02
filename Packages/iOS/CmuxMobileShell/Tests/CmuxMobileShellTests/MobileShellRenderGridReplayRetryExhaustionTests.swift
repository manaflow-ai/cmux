import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func renderGridReplayRetryExhaustionStopsLiveEventReplayRequests() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let surfaceID = "live-terminal"
    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let mountReplaySettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(mountReplaySettled)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    let transport = try #require(box.get())

    await router.holdNextReplayResponses()
    store.requestTerminalReplay(surfaceID: surfaceID)
    let oldReplayInFlight = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterMount + 1
    )
    #expect(oldReplayInFlight)

    await store.submitTerminalRawInput(Data("x".utf8), surfaceID: surfaceID)
    let inputSent = try await pollUntil { await router.count(of: "terminal.input") >= 1 }
    #expect(inputSent)
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 99,
        text: "dropped-event-before-exhaustion",
        full: false,
        columns: 40
    ))

    try await router.enqueueReplayRenderGrids([
        renderGridFrame(surfaceID: surfaceID, seq: 97, text: "stale-replay-1"),
        renderGridFrame(surfaceID: surfaceID, seq: 98, text: "stale-replay-2"),
        renderGridFrame(surfaceID: surfaceID, seq: 99, text: "stale-replay-3"),
    ])
    await router.releaseAllHeld()
    let exhaustedRetriesSent = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterMount + 3
    )
    #expect(exhaustedRetriesSent)
    let replaySettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(replaySettled)
    let replayCountAfterExhaustion = await router.count(of: "mobile.terminal.replay")

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 100,
        text: "delta-after-exhaustion",
        full: false,
        columns: 40
    ))
    let replayAfterExhaustion = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterExhaustion + 1,
        timeoutNanoseconds: 500_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!replayAfterExhaustion)
    let deltaDelivered = try await pollUntil(attempts: 50) {
        collector.lines.contains { $0.contains("delta-after-exhaustion") }
    }
    #expect(!deltaDelivered)
    collector.unmount()
}

private func renderGridFrame(surfaceID: String, seq: UInt64, text: String) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: seq,
        // Wide enough for the descriptive marker texts these tests paint;
        // frame validation rejects spans wider than the grid.
        columns: 40,
        rows: 4,
        rowSpans: [
            .init(row: 0, column: 0, text: text),
        ]
    )
}
