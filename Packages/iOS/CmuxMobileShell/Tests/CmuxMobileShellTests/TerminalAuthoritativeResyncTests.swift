import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func supersedingResyncInvalidatesOldReplayAcknowledgement() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["old-replay", "current-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let oldChunk = try #require(await iterator.next())
    #expect(String(data: oldChunk.data, encoding: .utf8) == "old-replay")
    let oldBarrier = try #require(store.terminalReplayBarrierTokensBySurfaceID[surfaceID])
    let replayCountBeforeResync = await router.count(of: "mobile.terminal.replay")

    await router.holdNextReplayResponses()
    store.resyncTerminalOutput(
        reason: "test_superseding_resync",
        restartEventStream: false,
        surfaceIDs: [surfaceID]
    )
    await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountBeforeResync + 1
    )
    let currentBarrier = try #require(store.terminalReplayBarrierTokensBySurfaceID[surfaceID])
    #expect(currentBarrier != oldBarrier)
    guard currentBarrier != oldBarrier else {
        await router.releaseAllHeld()
        return
    }

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: oldChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == currentBarrier)

    await router.releaseAllHeld()
    let currentChunk = try #require(await iterator.next())
    #expect(String(data: currentChunk.data, encoding: .utf8) == "current-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: currentChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
}
