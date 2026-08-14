import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func replayAtPendingInputSeqRetriesWhenBarrierAppearsAfterRequest() async throws {
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

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "old",
        full: true
    ))
    let oldDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("old") }
    }
    #expect(oldDelivered)

    store.pendingTerminalByteEndSeqBySurfaceID[surfaceID] = 12
    let staleReplayDropped = store.shouldDropRenderGridBehindPendingInput(
        try recoveryRenderGridFrame(surfaceID: surfaceID, seq: 3, text: "stale-replay"),
        source: "replay"
    )
    #expect(staleReplayDropped)
    #expect(store.pendingTerminalInputDroppedRenderGridSurfaceIDs.contains(surfaceID))

    await router.holdNextReplayResponses()
    try await router.enqueueReplayRenderGridFrames([
        recoveryRenderGridFrame(surfaceID: surfaceID, seq: 12, text: "current"),
        recoveryRenderGridFrame(surfaceID: surfaceID, seq: 12, text: "current"),
    ])
    store.requestTerminalReplay(surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)

    store.terminalReplayBarrierTokensBySurfaceID[surfaceID] = UUID()
    await router.releaseAllHeld()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 2)

    let currentDelivered = try await pollUntil {
        collector.lines.last?.contains("current") == true
    }
    #expect(currentDelivered)
    #expect(store.pendingTerminalByteEndSeqBySurfaceID[surfaceID] == nil)
    #expect(!store.pendingTerminalInputDroppedRenderGridSurfaceIDs.contains(surfaceID))
    collector.unmount()
}

private func recoveryRenderGridFrame(
    surfaceID: String,
    seq: UInt64,
    text: String
) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: seq,
        columns: 40,
        rows: 4,
        rowSpans: [
            .init(row: 0, column: 0, text: text),
        ]
    )
}
