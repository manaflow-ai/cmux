import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func sustainedTerminalOutputOverloadReplacesBacklogWithAuthoritativeReplay() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayPayload(text: "cold-replay", sequence: nil)
    await router.enqueueReplayRenderGrid(try renderGridFrame(
        surfaceID: surfaceID,
        seq: 200,
        text: "overload-replay"
    ))
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: coldReplayChunk.streamToken
    )
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.deliverTerminalBytes(Data("stalled-apply".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())

    for index in 0..<TerminalOutputDeliveryQueue.maximumPendingCount {
        let admitted = store.deliverTerminalBytes(
            Data("queued-\(index)".utf8),
            surfaceID: surfaceID
        )
        #expect(admitted)
    }
    #expect(
        store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount
            == TerminalOutputDeliveryQueue.maximumPendingCount
    )

    let overloadAdmitted = store.deliverTerminalBytes(
        Data("queue-overload".utf8),
        surfaceID: surfaceID
    )
    try #require(!overloadAdmitted)
    let replayStreamToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])
    #expect(replayStreamToken != stalledChunk.streamToken)
    #expect((store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount ?? 0) <= 1)

    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let overloadReplayChunk = try #require(await iterator.next())
    #expect(String(decoding: overloadReplayChunk.data, as: UTF8.self).contains("overload-replay"))
    #expect(overloadReplayChunk.streamToken == replayStreamToken)

    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: stalledChunk.streamToken
    )
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil)

    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: overloadReplayChunk.streamToken
    )
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.deliverTerminalBytes(Data("live-after-recovery".utf8), surfaceID: surfaceID)
    let recoveredChunk = try #require(await iterator.next())
    #expect(String(data: recoveredChunk.data, encoding: .utf8) == "live-after-recovery")
}

@MainActor
@Test func terminalOutputOverloadInvalidatesStaleAckWithoutRemoteClient() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()

    store.deliverTerminalBytes(Data("stalled-apply".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    for index in 0..<TerminalOutputDeliveryQueue.maximumPendingCount {
        #expect(store.deliverTerminalBytes(Data("queued-\(index)".utf8), surfaceID: surfaceID))
    }

    let overloadAdmitted = store.deliverTerminalBytes(
        Data("queue-overload".utf8),
        surfaceID: surfaceID
    )
    try #require(!overloadAdmitted)
    let replacementToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])
    try #require(replacementToken != stalledChunk.streamToken)
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: stalledChunk.streamToken
    )
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)

    #expect(store.deliverTerminalBytes(Data("live-after-recovery".utf8), surfaceID: surfaceID))
    let recoveredChunk = try #require(await iterator.next())
    #expect(recoveredChunk.streamToken == replacementToken)
    #expect(String(data: recoveredChunk.data, encoding: .utf8) == "live-after-recovery")
}

@MainActor
@Test func overloadFollowUpBarrierPreservesAuthoritativeReplacementRequirement() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay"])
    await router.enqueueReplayRenderGrid(try renderGridFrame(
        surfaceID: surfaceID,
        seq: 200,
        text: "first-overload-replay"
    ))
    await router.enqueueReplayRenderGrid(try renderGridFrame(
        surfaceID: surfaceID,
        seq: 201,
        text: "follow-up-overload-replay"
    ))
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: coldReplayChunk.streamToken
    )

    store.deliverTerminalBytes(Data("stalled-apply".utf8), surfaceID: surfaceID)
    _ = try #require(await iterator.next())
    for index in 0..<TerminalOutputDeliveryQueue.maximumPendingCount {
        #expect(store.deliverTerminalBytes(Data("queued-\(index)".utf8), surfaceID: surfaceID))
    }
    #expect(!store.deliverTerminalBytes(Data("overflow".utf8), surfaceID: surfaceID))

    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let firstReplacement = try #require(await iterator.next())
    #expect(
        String(decoding: firstReplacement.data, as: UTF8.self)
            .contains("first-overload-replay")
    )

    // Output that arrives after the first replacement request still belongs to
    // the overload gap. Completing the first chunk must carry that authority
    // into the follow-up barrier instead of silently downgrading it to a normal
    // byte-replay barrier.
    #expect(
        !store.deliverTerminalBytes(
            Data("output-after-first-overload-replay".utf8),
            surfaceID: surfaceID
        )
    )
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: firstReplacement.streamToken
    )

    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 3)
    #expect(
        store.terminalReplayOverloadReplacementSurfaceIDs.contains(surfaceID)
    )
    #expect(
        store.terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID),
        "a follow-up overload barrier must still owe the dropped output"
    )
    #expect(
        (store.terminalReplayBarrierDroppedOutputCountsBySurfaceID[surfaceID] ?? 0) > 0,
        "a follow-up overload barrier must retain a nonzero dropped-output floor"
    )

    let followUpReplacement = try #require(await iterator.next())
    #expect(
        String(decoding: followUpReplacement.data, as: UTF8.self)
            .contains("follow-up-overload-replay")
    )
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: followUpReplacement.streamToken
    )
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
}

@MainActor
@Test func exhaustedCompatibilityFallbackRebasesAfterSequenceReset() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"
    store.terminalOutputTransport = .hybrid

    // Establish a high pre-barrier sequence, then make every overload replay
    // return a compatibility snapshot from a restarted host sequence.
    await router.enqueueReplayPayload(text: "cold-replay", sequence: 100)
    for attempt in 0...MobileShellComposite.maxTerminalReplayFailureRetries {
        await router.enqueueReplayPayload(
            text: nil,
            sequence: 2,
            snapshotText: "sequence-reset-\(attempt)"
        )
    }
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(coldReplayChunk.endSequence == 100)
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: coldReplayChunk.streamToken
    )
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 100)

    store.deliverTerminalBytes(Data("stalled-apply".utf8), surfaceID: surfaceID)
    _ = try #require(await iterator.next())
    for index in 0..<TerminalOutputDeliveryQueue.maximumPendingCount {
        #expect(store.deliverTerminalBytes(Data("queued-\(index)".utf8), surfaceID: surfaceID))
    }
    #expect(!store.deliverTerminalBytes(Data("overflow".utf8), surfaceID: surfaceID))

    await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 2 + MobileShellComposite.maxTerminalReplayFailureRetries
    )
    let replacementChunk = try #require(await iterator.next())
    #expect(
        String(decoding: replacementChunk.data, as: UTF8.self)
            .contains("sequence-reset-\(MobileShellComposite.maxTerminalReplayFailureRetries)")
    )
    #expect(replacementChunk.endSequence == 2)
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: replacementChunk.streamToken
    )

    // The fallback starts a new sequence epoch. A subsequent live event must
    // not be rejected against the pre-barrier high-water mark.
    let transport = try #require(box.get())
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 3,
        text: "live-after-sequence-reset"
    ))
    let resumed = try await pollUntil {
        store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ==
            3 + UInt64("live-after-sequence-reset".utf8.count)
    }
    #expect(resumed)
    guard resumed else { return }
    let liveChunk = try #require(await iterator.next())
    #expect(
        String(decoding: liveChunk.data, as: UTF8.self) == "live-after-sequence-reset"
    )
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: liveChunk.streamToken
    )
}

@MainActor
@Test func overloadDoesNotTreatRawTailAsAuthoritativeReplacement() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayPayload(text: "cold-replay", sequence: nil)
    await router.enqueueReplayPayload(text: "raw-fallback-after-overload", sequence: nil)
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: coldReplayChunk.streamToken
    )

    store.deliverTerminalBytes(Data("stalled-apply".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    for index in 0..<TerminalOutputDeliveryQueue.maximumPendingCount {
        #expect(store.deliverTerminalBytes(Data("queued-\(index)".utf8), surfaceID: surfaceID))
    }
    #expect(!store.deliverTerminalBytes(Data("overflow".utf8), surfaceID: surfaceID))

    // The first overload replay returns only a raw tail. It must be rejected
    // as a replacement, retried within the bounded budget, and finally fail
    // the barrier open so live output can resume without reconnecting.
    let retriesSettled = try await pollUntil {
        await router.count(of: "mobile.terminal.replay")
            >= 1 + 1 + MobileShellComposite.maxTerminalReplayFailureRetries
    }
    #expect(retriesSettled)
    let recoverySettled = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(recoverySettled)

    #expect(store.deliverTerminalBytes(Data("live-after-raw-fallback".utf8), surfaceID: surfaceID))
    let recoveredChunk = try #require(await iterator.next())
    #expect(String(data: recoveredChunk.data, encoding: .utf8) == "live-after-raw-fallback")
    #expect(recoveredChunk.streamToken != stalledChunk.streamToken)
}

@MainActor
@Test func overloadRetryExhaustionInstallsBestEffortSnapshotReplacement() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"
    store.terminalOutputTransport = .renderGrid
    store.supportedHostCapabilities = [
        "terminal.render_grid.v1",
        MobileShellComposite.terminalVerifiedReplayCapability,
        "terminal.replay.v1",
    ]

    await router.enqueueReplayPayload(text: "cold-replay", sequence: nil)
    // Every recovery attempt (the replacement request plus each bounded
    // retry) returns only a VT snapshot; grid capture never succeeds.
    for attempt in 0...MobileShellComposite.maxTerminalReplayFailureRetries {
        await router.enqueueReplayPayload(
            text: nil,
            sequence: nil,
            snapshotText: "snapshot-attempt-\(attempt)"
        )
    }
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: coldReplayChunk.streamToken
    )

    store.deliverTerminalBytes(Data("stalled-apply".utf8), surfaceID: surfaceID)
    _ = try #require(await iterator.next())
    for index in 0..<TerminalOutputDeliveryQueue.maximumPendingCount {
        #expect(store.deliverTerminalBytes(Data("queued-\(index)".utf8), surfaceID: surfaceID))
    }
    #expect(!store.deliverTerminalBytes(Data("overflow".utf8), surfaceID: surfaceID))

    // Once the bounded retry budget is exhausted without an authoritative
    // grid, the final snapshot must land as a clearing replacement instead
    // of being discarded: the screen provably missed output.
    let replacementChunk = try #require(await iterator.next())
    let replacementText = String(decoding: replacementChunk.data, as: UTF8.self)
    #expect(
        !replacementChunk.requiresVerifiedReplay,
        "a best-effort compatibility replacement must use the legacy application path"
    )
    #expect(
        replacementChunk.requiresVerifiedReplayReset,
        "a compatibility replacement must reset any stale verified presentation baseline"
    )
    #expect(
        replacementText.hasPrefix("\u{1B}[H"),
        "an unknown active screen must be cleared without selecting a buffer"
    )
    #expect(!replacementText.contains("\u{1B}[?1049h"))
    #expect(replacementText.contains(
        "snapshot-attempt-\(MobileShellComposite.maxTerminalReplayFailureRetries)"
    ))
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: replacementChunk.streamToken
    )
    // The replacement covers only the visible screen; the mirror must be
    // marked for scrollback re-hydration on the next screen-anchored replay.
    #expect(store.terminalMirrorHydrationNeededSurfaceIDs.contains(surfaceID))
    let recoverySettled = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(recoverySettled)

    #expect(store.deliverTerminalBytes(Data("live-after-snapshot".utf8), surfaceID: surfaceID))
    let liveChunk = try #require(await iterator.next())
    #expect(String(data: liveChunk.data, encoding: .utf8) == "live-after-snapshot")
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: liveChunk.streamToken
    )

    // A persistent render-grid capture failure must still allow later deltas
    // through the bounded compatibility escape; otherwise each one would
    // reopen the replay barrier and repeat the exhausted retry cycle.
    let replayCountAfterFallback = await router.count(of: "mobile.terminal.replay")
    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 300,
        text: "delta-after-compatibility-fallback",
        full: false,
        anchor: .viewport
    ))
    let compatibilityDeltaQueued = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == false
    }
    #expect(compatibilityDeltaQueued)
    #expect(await router.count(of: "mobile.terminal.replay") == replayCountAfterFallback)
    guard compatibilityDeltaQueued else { return }
    let compatibilityDelta = try #require(await iterator.next())
    #expect(
        String(decoding: compatibilityDelta.data, as: UTF8.self)
            .contains("delta-after-compatibility-fallback")
    )
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: compatibilityDelta.streamToken
    )
}

@MainActor
@Test func overloadReplayWithoutFallbackFailsOpenAndResumesLiveOutput() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay"])
    await router.enqueueEmptyReplayResponses(
        count: 1 + MobileShellComposite.maxTerminalReplayFailureRetries
    )
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: coldReplayChunk.streamToken
    )

    store.deliverTerminalBytes(Data("stalled-apply".utf8), surfaceID: surfaceID)
    _ = try #require(await iterator.next())
    for index in 0..<TerminalOutputDeliveryQueue.maximumPendingCount {
        #expect(store.deliverTerminalBytes(Data("queued-\(index)".utf8), surfaceID: surfaceID))
    }
    #expect(!store.deliverTerminalBytes(Data("overflow".utf8), surfaceID: surfaceID))

    let replayAttempts = 2 + MobileShellComposite.maxTerminalReplayFailureRetries
    let exhausted = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayAttempts
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(
        exhausted,
        "an exhausted replay with no compatibility payload must release its barrier"
    )

    #expect(store.deliverTerminalBytes(Data("live-after-empty-replay".utf8), surfaceID: surfaceID))
    let liveChunk = try #require(await iterator.next())
    #expect(String(data: liveChunk.data, encoding: .utf8) == "live-after-empty-replay")
}
