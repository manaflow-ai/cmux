import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func replayRequestedDuringInFlightBarrierIsOwnedAsFollowUp() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "first-replay", "follow-up-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let coldReplaySettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(coldReplaySettled)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    await router.holdNextReplayResponses()
    defer { Task { await router.releaseAllHeld() } }
    let replayBarrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    store.requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)

    store.requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    #expect(store.terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] == 1)

    await router.releaseAllHeld()
    let firstReplayChunk = try #require(await iterator.next())
    #expect(String(data: firstReplayChunk.data, encoding: .utf8) == "first-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: firstReplayChunk.streamToken)
    let followUpRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterMount + 2,
        recordIssueOnTimeout: false
    )
    #expect(followUpRequested)
    guard followUpRequested else { return }

    let followUpReplayChunk = try #require(await iterator.next())
    #expect(String(data: followUpReplayChunk.data, encoding: .utf8) == "follow-up-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: followUpReplayChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
}

@MainActor
@Test func retainedOutputSurvivesColdReplayFollowUpFailureEpisode() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay-A"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay-A")

    let retainedAccepted = store.deliverTerminalBytes(
        Data("retained-during-A".utf8),
        surfaceID: surfaceID
    )
    #expect(!retainedAccepted)
    await router.failNextReplay(count: 3)
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: coldReplayChunk.streamToken
    )
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 4)

    let failedOpen = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(failedOpen)
    let retainedOutputQueued = store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == false
    #expect(
        retainedOutputQueued,
        "retained output from replay A must survive token rollover until replay B fails open"
    )
    guard retainedOutputQueued else { return }

    let retainedChunk = try #require(await iterator.next())
    #expect(String(data: retainedChunk.data, encoding: .utf8) == "retained-during-A")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: retainedChunk.streamToken)

    _ = store.deliverTerminalBytes(Data("live-after".utf8), surfaceID: surfaceID)
    let liveAfterChunk = try #require(await iterator.next())
    #expect(String(data: liveAfterChunk.data, encoding: .utf8) == "live-after")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: liveAfterChunk.streamToken)
}

@MainActor
@Test func retainedOutputSurvivesEmptyFollowUpReplay() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "replay-A"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let coldReplaySettled = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(coldReplaySettled)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    let replayBarrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    store.requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)
    let replayAChunk = try #require(await iterator.next())
    #expect(String(data: replayAChunk.data, encoding: .utf8) == "replay-A")

    let retainedAccepted = store.deliverTerminalBytes(
        Data("retained-during-A".utf8),
        surfaceID: surfaceID
    )
    #expect(!retainedAccepted)
    await router.enqueueEmptyReplayResponses()
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayAChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 2)

    let emptyFollowUpSettled = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(emptyFollowUpSettled)
    let retainedOutputQueued = store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == false
    #expect(
        retainedOutputQueued,
        "an empty follow-up is not authoritative and must reconcile A-era retained output"
    )
    guard retainedOutputQueued else { return }

    let retainedChunk = try #require(await iterator.next())
    #expect(String(data: retainedChunk.data, encoding: .utf8) == "retained-during-A")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: retainedChunk.streamToken)

    _ = store.deliverTerminalBytes(Data("live-after-empty-B".utf8), surfaceID: surfaceID)
    let liveAfterChunk = try #require(await iterator.next())
    #expect(String(data: liveAfterChunk.data, encoding: .utf8) == "live-after-empty-B")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: liveAfterChunk.streamToken)
}

@MainActor
@Test func replayRequestedAfterResponseEnqueueWaitsForAcknowledgementOwnedFollowUp() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "first-replay", "follow-up-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let coldReplaySettled = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(coldReplaySettled)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    let replayBarrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    store.requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)
    let firstReplayChunk = try #require(await iterator.next())
    let firstResponseAwaitingAcknowledgement = try await pollUntil {
        store.terminalReplayBarrierAckStreamTokensBySurfaceID[surfaceID] == firstReplayChunk.streamToken
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(firstResponseAwaitingAcknowledgement)

    store.requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    #expect(!store.terminalReplaySurfaceIDsInFlight.contains(surfaceID))
    #expect(store.terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] == 1)
    #expect(await router.count(of: "mobile.terminal.replay") == replayCountAfterMount + 1)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: firstReplayChunk.streamToken)
    let followUpRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterMount + 2,
        recordIssueOnTimeout: false
    )
    #expect(followUpRequested)
    guard followUpRequested else { return }

    let followUpReplayChunk = try #require(await iterator.next())
    #expect(String(data: followUpReplayChunk.data, encoding: .utf8) == "follow-up-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: followUpReplayChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
}

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
    #expect(store.pendingTerminalByteEndSeqBySurfaceID[surfaceID] == nil)
    #expect(!store.pendingTerminalInputDroppedRenderGridSurfaceIDs.contains(surfaceID))

    let retainedOutputQueued = store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == false
    #expect(retainedOutputQueued, "the real output dropped during the follow-up barrier must be retained")
    guard retainedOutputQueued else { return }

    let recoveredAfterFailOpen = try #require(await iterator.next())
    #expect(String(data: recoveredAfterFailOpen.data, encoding: .utf8) == "live-during-follow-up-barrier")
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: recoveredAfterFailOpen.streamToken
    )

    store.deliverTerminalBytes(Data("after-bounded-replay".utf8), surfaceID: surfaceID)
    let afterBoundedReplay = try #require(await iterator.next())
    #expect(String(data: afterBoundedReplay.data, encoding: .utf8) == "after-bounded-replay")
}

@MainActor
@Test func followUpCapFailOpenReconcilesRetainedRenderGridDelta() async throws {
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

    let failedOpenWithRetainedDelta = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 57
    }
    #expect(failedOpenWithRetainedDelta)

    let retainedDeltaChunk = try #require(await iterator.next())
    let retainedDeltaText = try #require(String(data: retainedDeltaChunk.data, encoding: .utf8))
    #expect(retainedDeltaText.contains("delta-dropped-by-follow-up-barrier"))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: retainedDeltaChunk.streamToken)

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
@Test func followUpCapFailOpenReconcilesRetainedRawByteIntervals() async throws {
    let router = LivenessHostRouter()
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
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 0,
        text: "BASE"
    ))
    let baselineChunk = try #require(await iterator.next())
    #expect(String(data: baselineChunk.data, encoding: .utf8) == "BASE")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: baselineChunk.streamToken)
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 4)

    await router.enqueueReplayPayload(text: "first-replay", sequence: 10)
    await router.enqueueReplayPayload(text: "follow-up-replay", sequence: 12)
    await router.holdNextReplayResponses()
    let firstBarrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    store.requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: firstBarrierToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)

    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "123456"
    ))
    let firstDropRecorded = try await pollUntil {
        store.terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] == 1
    }
    #expect(firstDropRecorded)
    await router.releaseAllHeld()

    let firstReplayChunk = try #require(await iterator.next())
    #expect(String(data: firstReplayChunk.data, encoding: .utf8) == "first-replay")
    await router.holdNextReplayResponses()
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: firstReplayChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 3)

    // This event spans [8, 16). The pre-barrier floor is 10, then the held
    // follow-up replay advances the authoritative high-water mark to 12. A
    // fail-open must therefore release only [12, 16), not the [10, 12)
    // overlap that was retained before the replay response arrived.
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 8,
        text: "ABCDEFGH"
    ))
    let followUpDropRecorded = try await pollUntil {
        store.terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] == 1
    }
    #expect(followUpDropRecorded)
    await router.releaseAllHeld()

    let followUpReplayChunk = try #require(await iterator.next())
    #expect(String(data: followUpReplayChunk.data, encoding: .utf8) == "follow-up-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: followUpReplayChunk.streamToken)

    let retainedSuffixChunk = try #require(await iterator.next())
    #expect(
        String(data: retainedSuffixChunk.data, encoding: .utf8) == "EFGH",
        "fail-open must trim retained bytes already covered by the replay high-water mark"
    )
    #expect(
        store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 16,
        "releasing retained bytes must advance the delivered sequence to their interval end"
    )
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: retainedSuffixChunk.streamToken)

    // [14, 18) overlaps the reconciled suffix by two bytes. A truthful mark
    // at 16 trims the duplicate prefix and delivers only the contiguous tail.
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 14,
        text: "GH++"
    ))
    let postFailOpenChunk = try #require(await iterator.next())
    #expect(
        String(data: postFailOpenChunk.data, encoding: .utf8) == "++",
        "the next event must neither duplicate reconciled bytes nor be treated as a gap"
    )
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 18)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: postFailOpenChunk.streamToken)
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
