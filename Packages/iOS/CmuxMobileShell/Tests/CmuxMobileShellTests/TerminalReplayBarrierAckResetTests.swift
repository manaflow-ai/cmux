import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func terminalReplayBarrierCapsRepeatedReplayAckResets() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts([
        "cold-replay",
        "first-replay",
        "second-replay",
        "third-replay",
        "unexpected-replay",
    ])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    store.deliverTerminalBytes(Data("stalled-first".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: stalledChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)

    let firstReplayChunk = try #require(await iterator.next())
    #expect(String(data: firstReplayChunk.data, encoding: .utf8) == "first-replay")
    let barrierToken = try #require(store.terminalReplayBarrierTokensBySurfaceID[surfaceID])

    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: firstReplayChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 2)
    let secondReplayChunk = try #require(await iterator.next())
    #expect(String(data: secondReplayChunk.data, encoding: .utf8) == "second-replay")
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == barrierToken)

    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: secondReplayChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 3)
    let thirdReplayChunk = try #require(await iterator.next())
    #expect(String(data: thirdReplayChunk.data, encoding: .utf8) == "third-replay")
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == barrierToken)

    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: thirdReplayChunk.streamToken)
    let replayRestartedAfterExhaustion = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterMount + 4,
        recordIssueOnTimeout: false
    )
    #expect(!replayRestartedAfterExhaustion, "replay ack resets must not bypass the replay retry cap")
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == barrierToken)
}
