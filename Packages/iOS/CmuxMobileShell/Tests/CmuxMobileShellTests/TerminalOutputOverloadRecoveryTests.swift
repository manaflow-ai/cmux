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
