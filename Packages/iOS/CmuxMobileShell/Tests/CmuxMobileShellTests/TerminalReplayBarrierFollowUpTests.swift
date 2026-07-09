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
    let queuedReplayTailAccepted = store.deliverTerminalBytes(
        Data("queued-after-follow-up-cap".utf8),
        surfaceID: surfaceID,
        bypassReplayBarrier: true
    )
    #expect(queuedReplayTailAccepted == true)
    store.pendingTerminalByteEndSeqBySurfaceID[surfaceID] = 100
    store.pendingTerminalInputDroppedRenderGridSurfaceIDs.insert(surfaceID)
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
    #expect(store.pendingTerminalByteEndSeqBySurfaceID[surfaceID] == nil)
    #expect(!store.pendingTerminalInputDroppedRenderGridSurfaceIDs.contains(surfaceID))

    let queuedAfterFailOpen = try #require(await iterator.next())
    #expect(String(data: queuedAfterFailOpen.data, encoding: .utf8) == "queued-after-follow-up-cap")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: queuedAfterFailOpen.streamToken)

    store.terminalOutputTransport = .renderGrid
    store.deliverAuthoritativeTerminalRenderGrid(
        try renderGridFrame(surfaceID: surfaceID, seq: 100, text: "live-grid-after-fail-open"),
        source: "event"
    )
    let liveGridAfterFailOpen = try #require(await iterator.next())
    let liveGridText = try #require(String(data: liveGridAfterFailOpen.data, encoding: .utf8))
    #expect(liveGridText.contains("live-grid-after-fail-open"))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: liveGridAfterFailOpen.streamToken)

    store.deliverTerminalBytes(Data("after-bounded-replay".utf8), surfaceID: surfaceID)
    let afterBoundedReplay = try #require(await iterator.next())
    #expect(String(data: afterBoundedReplay.data, encoding: .utf8) == "after-bounded-replay")
}

@MainActor
@Test func followUpCapFailOpenRestoresBaselineForPartialRenderGridDelta() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplaySettled = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(coldReplaySettled)

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 50,
        text: "baseline-before-follow-up-cap",
        full: true
    ))
    let baselineChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: baselineChunk.streamToken)
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 50)

    await router.enqueueReplayRenderGrid(try renderGridFrame(
        surfaceID: surfaceID,
        seq: 55,
        text: "first-replay",
        full: true
    ))
    let firstBarrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    store.requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: firstBarrierToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let firstReplayChunk = try #require(await iterator.next())

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 56,
        text: "delta-dropped-by-first-barrier",
        full: false
    ))
    let firstDropRecorded = try await pollUntil {
        store.terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] == 1
    }
    #expect(firstDropRecorded)
    await router.enqueueReplayPayload(text: "follow-up-without-sequence", sequence: nil)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: firstReplayChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 3)

    let followUpChunk = try #require(await iterator.next())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 57,
        text: "delta-dropped-by-follow-up-barrier",
        full: false
    ))
    let followUpDropRecorded = try await pollUntil {
        store.terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] == 1
    }
    #expect(followUpDropRecorded)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: followUpChunk.streamToken)

    let failedOpenWithRestoredBaseline = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 55
    }
    #expect(failedOpenWithRestoredBaseline)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 60,
        text: "partial-delta-after-follow-up-cap",
        full: false
    ))
    let partialDeltaChunk = try #require(await iterator.next())
    let partialDeltaText = try #require(String(data: partialDeltaChunk.data, encoding: .utf8))
    #expect(partialDeltaText.contains("partial-delta-after-follow-up-cap"))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: partialDeltaChunk.streamToken)
}

@MainActor
@Test func terminalReplayBarrierFailsOpenAfterDroppedOutputCap() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    store.deliverTerminalBytes(Data("stalled-first".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: stalledChunk.streamToken)
    _ = try #require(store.terminalReplayBarrierTokensBySurfaceID[surfaceID])

    for index in 0..<Int(MobileShellComposite.maxTerminalReplayBarrierDroppedOutputBeforeFailOpen) {
        _ = store.deliverTerminalBytes(Data("drop-\(index)".utf8), surfaceID: surfaceID)
    }

    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
    let deliveredAfterCap = try #require(await iterator.next())
    #expect(String(data: deliveredAfterCap.data, encoding: .utf8)?.hasPrefix("drop-") == true)
}
