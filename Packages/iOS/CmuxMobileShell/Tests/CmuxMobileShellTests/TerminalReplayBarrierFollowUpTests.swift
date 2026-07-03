import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func terminalReplayBarrierCapsFollowUpReplaysUnderContinuousOutput() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts([
        "cold-replay",
        "first-replay",
        "follow-up-replay",
        "unexpected-second-follow-up",
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

    let replayChunk = try #require(await iterator.next())
    #expect(String(data: replayChunk.data, encoding: .utf8) == "first-replay")
    let firstDropAccepted = store.deliverTerminalBytes(
        Data("live-during-first-barrier".utf8),
        surfaceID: surfaceID
    )
    #expect(firstDropAccepted == false)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 2)

    let followUpChunk = try #require(await iterator.next())
    #expect(String(data: followUpChunk.data, encoding: .utf8) == "follow-up-replay")
    let followUpDropAccepted = store.deliverTerminalBytes(
        Data("live-during-follow-up-barrier".utf8),
        surfaceID: surfaceID
    )
    #expect(followUpDropAccepted == false)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: followUpChunk.streamToken)
    let secondFollowUpRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterMount + 3,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!secondFollowUpRequested, "continuous output must not keep replaying indefinitely")
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.deliverTerminalBytes(Data("after-bounded-replay".utf8), surfaceID: surfaceID)
    let afterBoundedReplay = try #require(await iterator.next())
    #expect(String(data: afterBoundedReplay.data, encoding: .utf8) == "after-bounded-replay")
}
