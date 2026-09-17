import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7160:
// after a viewport geometry change (keyboard show/hide, rotation, zoom), the
// mirrored terminal's raw-byte stream is not geometry-faithful until the Mac
// has re-pinned its grid, and nothing repaints rows the TUI does not own. The
// store must arm a replay barrier and re-request authoritative state once the
// Mac acknowledges the new viewport, so stale-geometry output is dropped and
// the resized grid is repainted from a fresh snapshot instead of compositing
// rows from the old geometry onto the new one.

@MainActor
@Test func terminalViewportGeometryChangeRequestsAuthoritativeReplay() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts([
        "cold-replay",
        "initial-viewport-replay",
        "viewport-resync-replay",
        "viewport-resync-follow-up",
    ])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    // The first viewport report after mount establishes the effective geometry.
    // A cold replay may have been captured at the Mac's old grid before the
    // viewport acknowledgement applies, so the first acknowledged grid requests
    // one authoritative replay.
    let replayCountAfterColdAttach = await router.count(of: "mobile.terminal.replay")
    let baselineGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    #expect(baselineGrid?.columns == 80)
    #expect(baselineGrid?.rows == 48)
    let initialViewportReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterColdAttach + 1
    )
    #expect(
        initialViewportReplayRequested,
        "the first acknowledged viewport for an attached sink must request replay"
    )
    let initialViewportChunk = try #require(await iterator.next())
    #expect(String(data: initialViewportChunk.data, encoding: .utf8) == "initial-viewport-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    store.deliverTerminalBytes(Data("live-before-resize".utf8), surfaceID: surfaceID)
    let liveChunk = try #require(await iterator.next())
    #expect(String(data: liveChunk.data, encoding: .utf8) == "live-before-resize")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: liveChunk.streamToken)

    // Keyboard opened: the grid loses rows. Once the Mac acknowledges the new
    // viewport, the store must arm a replay barrier and request authoritative
    // state, because output produced for the old geometry cannot be applied
    // faithfully to the resized grid.
    await router.holdNextReplayResponses(count: 1)
    let resizedGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 30)
    #expect(resizedGrid?.rows == 30)
    let viewportReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 1
    )
    #expect(
        viewportReplayRequested,
        "a viewport geometry change must request an authoritative replay"
    )
    guard viewportReplayRequested else {
        await router.releaseAllHeld()
        return
    }

    // Output emitted for the stale geometry while the replay is in flight is
    // dropped by the barrier instead of painting rows at the wrong positions.
    let staleAccepted = store.deliverTerminalBytes(
        Data("stale-old-geometry".utf8),
        surfaceID: surfaceID
    )
    #expect(staleAccepted == false, "stale-geometry output must be dropped behind the replay barrier")

    await router.releaseAllHeld()
    let resyncChunk = try #require(await iterator.next())
    #expect(String(data: resyncChunk.data, encoding: .utf8) == "viewport-resync-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: resyncChunk.streamToken)

    // Output was dropped while the barrier was armed, so the store follows up
    // with one more replay; drain it so the barrier clears.
    let followUpRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 2
    )
    guard followUpRequested else { return }
    let followUpChunk = try #require(await iterator.next())
    #expect(String(data: followUpChunk.data, encoding: .utf8) == "viewport-resync-follow-up")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: followUpChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    // Live output at the new geometry resumes once the resync completes.
    store.deliverTerminalBytes(Data("live-after-resync".utf8), surfaceID: surfaceID)
    let resumedChunk = try #require(await iterator.next())
    #expect(String(data: resumedChunk.data, encoding: .utf8) == "live-after-resync")
}

@MainActor
@Test func terminalViewportSameSizeReportDoesNotRequestReplay() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "initial-viewport-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initialViewportChunk = try #require(await iterator.next())
    #expect(String(data: initialViewportChunk.data, encoding: .utf8) == "initial-viewport-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    // A same-size re-report (a geometry reassert, or a retried report after a
    // transient RPC drop that never changed the grid) is not a geometry change
    // and must not restart the output pipeline.
    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let extraReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!extraReplayRequested, "a same-size viewport re-report must not trigger a replay")

    store.deliverTerminalBytes(Data("live-after-reassert".utf8), surfaceID: surfaceID)
    let liveChunk = try #require(await iterator.next())
    #expect(String(data: liveChunk.data, encoding: .utf8) == "live-after-reassert")
}

@MainActor
@Test func terminalViewportDropsOutputWhileResizeAcknowledgementIsInFlight() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "initial-viewport-replay", "resize-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initialViewportChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    await router.holdViewportRequest(number: 2)
    let resizeReport = Task {
        await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 30)
    }
    await router.waitForCount(of: "mobile.terminal.viewport", atLeast: 2)

    let staleAccepted = store.deliverTerminalBytes(
        Data("stale-during-viewport-ack".utf8),
        surfaceID: surfaceID
    )
    #expect(!staleAccepted, "output must be dropped while a resize acknowledgement is in flight")
    store.requestTerminalReplay(surfaceID: surfaceID)
    let replayBeforeAck = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!replayBeforeAck, "pre-ACK drops must wait for the effective grid before replaying")

    await router.releaseAllHeld()
    let resizedGrid = await resizeReport.value
    #expect(resizedGrid?.rows == 30)
    let replayAfterAck = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 1
    )
    #expect(replayAfterAck, "the acknowledged resize must request replay")
    let resizeReplayChunk = try #require(await iterator.next())
    #expect(String(data: resizeReplayChunk.data, encoding: .utf8) == "resize-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: resizeReplayChunk.streamToken)
}

@MainActor
@Test func terminalViewportIgnoresStaleResizeAcknowledgements() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "latest-viewport-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let replayCountAfterColdAttach = await router.count(of: "mobile.terminal.replay")

    await router.holdViewportRequest(number: 1)
    let staleReport = Task {
        await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    }
    await router.waitForCount(of: "mobile.terminal.viewport", atLeast: 1)

    let latestGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 30)
    #expect(latestGrid?.columns == 80)
    #expect(latestGrid?.rows == 30)
    let latestReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterColdAttach + 1
    )
    #expect(latestReplayRequested, "the latest first acknowledgement must request replay")
    let latestReplayChunk = try #require(await iterator.next())
    #expect(String(data: latestReplayChunk.data, encoding: .utf8) == "latest-viewport-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: latestReplayChunk.streamToken)
    let replayCountAfterLatestAcknowledgement = await router.count(of: "mobile.terminal.replay")

    await router.releaseAllHeld()
    let staleGrid = await staleReport.value
    #expect(staleGrid?.columns == nil)
    #expect(staleGrid?.rows == nil)

    let staleReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterLatestAcknowledgement + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!staleReplayRequested, "a stale viewport acknowledgement must not request replay")
}

@MainActor
@Test func terminalViewportReversalCarriesPendingResizeBarrierForward() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts([
        "cold-replay",
        "initial-viewport-replay",
        "reverted-viewport-replay",
    ])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initialViewportChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    await router.holdViewportRequest(number: 2)
    let staleResizeReport = Task {
        await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 30)
    }
    await router.waitForCount(of: "mobile.terminal.viewport", atLeast: 2)

    let staleAccepted = store.deliverTerminalBytes(
        Data("stale-during-reversal".utf8),
        surfaceID: surfaceID
    )
    #expect(!staleAccepted, "output must be dropped while the superseded resize ACK is pending")

    let revertedGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    #expect(revertedGrid?.columns == 80)
    #expect(revertedGrid?.rows == 48)
    let replayAfterRevert = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 1
    )
    #expect(replayAfterRevert, "the reverted ACK must replay output dropped under the carried barrier")
    let replayChunk = try #require(await iterator.next())
    #expect(String(data: replayChunk.data, encoding: .utf8) == "reverted-viewport-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    await router.releaseAllHeld()
    let staleGrid = await staleResizeReport.value
    #expect(staleGrid?.columns == nil)
    #expect(staleGrid?.rows == nil)
    let extraReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 2,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!extraReplayRequested, "the stale resize ACK must not clear or replay after the revert")
}

@MainActor
@Test func terminalViewportSameNaturalReportUnderCappedGridDoesNotPrearmBarrier() async throws {
    let router = LivenessHostRouter()
    await router.setViewportEffectiveGrid(columns: 80, rows: 30)
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "initial-viewport-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    let baselineGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 100, rows: 50)
    #expect(baselineGrid?.columns == 80)
    #expect(baselineGrid?.rows == 30)
    let initialViewportChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    await router.holdViewportRequest(number: 2)
    let repeatReport = Task {
        await store.updateTerminalViewport(surfaceID: surfaceID, columns: 100, rows: 50)
    }
    await router.waitForCount(of: "mobile.terminal.viewport", atLeast: 2)

    let liveAccepted = store.deliverTerminalBytes(
        Data("live-while-repeat-held".utf8),
        surfaceID: surfaceID
    )
    #expect(liveAccepted, "same natural report must not prearm a barrier while the effective grid is capped")
    let liveChunk = try #require(await iterator.next())
    #expect(String(data: liveChunk.data, encoding: .utf8) == "live-while-repeat-held")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: liveChunk.streamToken)

    await router.releaseAllHeld()
    let repeatedGrid = await repeatReport.value
    #expect(repeatedGrid?.columns == 80)
    #expect(repeatedGrid?.rows == 30)
    let extraReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!extraReplayRequested, "same natural report under the same effective grid must not replay")
}

@MainActor
@Test func terminalViewportPrearmedBarrierWithoutResizeReplaysDiscardedOutput() async throws {
    let router = LivenessHostRouter()
    await router.setViewportEffectiveGrid(columns: 80, rows: 30)
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts([
        "cold-replay",
        "initial-viewport-replay",
        "post-prearm-replay",
    ])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    let baselineGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 100, rows: 50)
    #expect(baselineGrid?.columns == 80)
    #expect(baselineGrid?.rows == 30)
    let initialViewportChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    // Two live chunks the surface has not applied yet: one yielded to the
    // stream and one queued behind it. Pre-arming a barrier resets this
    // queue, so the queued chunk can never reach the surface.
    #expect(store.deliverTerminalBytes(Data("undelivered-live-a".utf8), surfaceID: surfaceID))
    #expect(store.deliverTerminalBytes(Data("undelivered-live-b".utf8), surfaceID: surfaceID))

    // A changed natural report pre-arms the barrier even though the capped
    // effective grid comes back unchanged, so the report resolves without a
    // resize. The discarded output must still be replaced by a replay
    // instead of silently resuming live output with a gap.
    let repeatedGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 120, rows: 60)
    #expect(repeatedGrid?.columns == 80)
    #expect(repeatedGrid?.rows == 30)
    let replayAfterPrearm = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 1
    )
    #expect(
        replayAfterPrearm,
        "a prearmed barrier that discarded undelivered output must replay when the report resolves without a resize"
    )
    guard replayAfterPrearm else { return }

    // The chunk yielded before the pre-arm still drains from the stream
    // buffer; its stream token is stale, so processing it is a no-op.
    let staleYieldedChunk = try #require(await iterator.next())
    #expect(String(data: staleYieldedChunk.data, encoding: .utf8) == "undelivered-live-a")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: staleYieldedChunk.streamToken)

    let replayChunk = try #require(await iterator.next())
    #expect(String(data: replayChunk.data, encoding: .utf8) == "post-prearm-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    // Live output resumes once the replay covered the discarded bytes.
    store.deliverTerminalBytes(Data("live-after-prearm-replay".utf8), surfaceID: surfaceID)
    let resumedChunk = try #require(await iterator.next())
    #expect(String(data: resumedChunk.data, encoding: .utf8) == "live-after-prearm-replay")
}

@MainActor
@Test func terminalViewportPrearmCancelledColdReplayIsReplacedWhenReportResolvesWithoutGrid() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    // Keep the cold-attach replay in flight while the first viewport report
    // races it, and answer that report without an effective grid.
    await router.holdNextReplayResponses(count: 1)
    await router.enqueueReplayTexts(["recovery-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)

    await router.emptyNextViewportResponses()
    let reportedGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    #expect(reportedGrid == nil)

    // Pre-arming the barrier cancelled the cold replay; resolving without a
    // grid must request a replacement replay instead of leaving the mounted
    // surface blank until some later event.
    let replacementRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 2
    )
    #expect(
        replacementRequested,
        "a prearm that cancelled the cold replay must replay when the report resolves without a grid"
    )
    guard replacementRequested else {
        await router.releaseAllHeld()
        return
    }

    let recoveryChunk = try #require(await iterator.next())
    #expect(String(data: recoveryChunk.data, encoding: .utf8) == "recovery-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: recoveryChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    // Releasing the stale cold response after the fact must not disturb the
    // recovered stream.
    await router.releaseAllHeld()
    store.deliverTerminalBytes(Data("live-after-recovery".utf8), surfaceID: surfaceID)
    let liveChunk = try #require(await iterator.next())
    #expect(String(data: liveChunk.data, encoding: .utf8) == "live-after-recovery")
}

@MainActor
@Test func terminalViewportPendingAckReplaysRecoveryRequestSuppressedDuringAck() async throws {
    let router = LivenessHostRouter()
    await router.setViewportEffectiveGrid(columns: 80, rows: 30)
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts([
        "cold-replay",
        "initial-viewport-replay",
        "deferred-recovery-replay",
    ])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    let baselineGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 100, rows: 50)
    #expect(baselineGrid?.columns == 80)
    #expect(baselineGrid?.rows == 30)
    let initialViewportChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    // A changed natural report is in flight (pre-ACK) while the capped
    // effective grid will come back unchanged.
    await router.holdViewportRequest(number: 2)
    let pendingReport = Task {
        await store.updateTerminalViewport(surfaceID: surfaceID, columns: 120, rows: 60)
    }
    await router.waitForCount(of: "mobile.terminal.viewport", atLeast: 2)

    // A recovery path (liveness probe repair, resync, advisory) asks for an
    // authoritative replay. It must defer to the pending acknowledgement,
    // not fire a competing replay.
    store.requestTerminalReplay(surfaceID: surfaceID)
    let competingReplay = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!competingReplay, "recovery replays must defer to the pending viewport acknowledgement")

    // When the report resolves without a resize, the deferred recovery
    // request must be serviced instead of silently discarded.
    await router.releaseAllHeld()
    let repeatedGrid = await pendingReport.value
    #expect(repeatedGrid?.columns == 80)
    #expect(repeatedGrid?.rows == 30)
    let deferredReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 1
    )
    #expect(
        deferredReplayRequested,
        "a without-resize resolution must replay the recovery request suppressed during the acknowledgement"
    )
    guard deferredReplayRequested else { return }

    let recoveryChunk = try #require(await iterator.next())
    #expect(String(data: recoveryChunk.data, encoding: .utf8) == "deferred-recovery-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: recoveryChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.deliverTerminalBytes(Data("live-after-deferred-replay".utf8), surfaceID: surfaceID)
    let liveChunk = try #require(await iterator.next())
    #expect(String(data: liveChunk.data, encoding: .utf8) == "live-after-deferred-replay")
}

@MainActor
@Test func terminalPipelineResetDuringViewportAckDefersToAckReplay() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts([
        "cold-replay",
        "initial-viewport-replay",
        "post-reset-resize-replay",
    ])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initialViewportChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    // A resize acknowledgement is pending while the render pipeline resets
    // (keyboard/rotation is exactly when drawable resets happen).
    await router.holdViewportRequest(number: 2)
    let resizeReport = Task {
        await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 30)
    }
    await router.waitForCount(of: "mobile.terminal.viewport", atLeast: 2)

    store.terminalOutputNeedsReplay(surfaceID: surfaceID)
    let replayDuringAck = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(
        !replayDuringAck,
        "a pipeline reset during a pending viewport acknowledgement must defer its replay to the acknowledgement"
    )

    // The acknowledged resize must still request the authoritative replay
    // (the reset must not have armed a competing barrier it dedupes against).
    await router.releaseAllHeld()
    let resizedGrid = await resizeReport.value
    #expect(resizedGrid?.rows == 30)
    let ackReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 1
    )
    #expect(ackReplayRequested, "the acknowledged resize must request the post-resize replay")
    guard ackReplayRequested else { return }

    let replayChunk = try #require(await iterator.next())
    #expect(String(data: replayChunk.data, encoding: .utf8) == "post-reset-resize-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.deliverTerminalBytes(Data("live-after-reset-resize".utf8), surfaceID: surfaceID)
    let liveChunk = try #require(await iterator.next())
    #expect(String(data: liveChunk.data, encoding: .utf8) == "live-after-reset-resize")
}

@MainActor
@Test func terminalEffectiveGridChangeWithoutPrearmReplacesUnrelatedInFlightReplay() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts([
        "cold-replay",
        "initial-viewport-replay",
        "post-effective-resize-replay",
    ])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initialViewportChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    // A pipeline reset starts a replay that stays in flight (captured before
    // the effective grid changes below).
    await router.holdNextReplayResponses(count: 1)
    store.terminalOutputNeedsReplay(surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterBaseline + 1)

    // The same natural report now acknowledges a different effective grid
    // (another device's pin changed), so no barrier was prearmed. The resize
    // must not dedupe its replay against the stale in-flight reset replay.
    await router.setViewportEffectiveGrid(columns: 80, rows: 30)
    let resizedGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    #expect(resizedGrid?.rows == 30)
    let postResizeReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 2
    )
    #expect(
        postResizeReplayRequested,
        "an effective-grid change must request its own replay instead of reusing the stale in-flight one"
    )
    guard postResizeReplayRequested else {
        await router.releaseAllHeld()
        return
    }

    let replayChunk = try #require(await iterator.next())
    #expect(String(data: replayChunk.data, encoding: .utf8) == "post-effective-resize-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    // The superseded reset replay resolves afterwards and must be discarded.
    await router.releaseAllHeld()
    store.deliverTerminalBytes(Data("live-after-effective-resize".utf8), surfaceID: surfaceID)
    let liveChunk = try #require(await iterator.next())
    #expect(String(data: liveChunk.data, encoding: .utf8) == "live-after-effective-resize")
}

@MainActor
@Test func terminalViewportSupersededSendPreservesPrearmedBarrier() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts([
        "cold-replay",
        "initial-viewport-replay",
        "superseding-resize-replay",
    ])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initialViewportChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    // The report scheduler cancels an in-flight send when a newer geometry
    // report supersedes it. The cancelled send must not resolve the pre-ACK
    // barrier it prearmed; the superseding report owns it.
    await router.holdViewportRequest(number: 2)
    let supersededReport = Task {
        await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 30)
    }
    await router.waitForCount(of: "mobile.terminal.viewport", atLeast: 2)
    let prearmedBarrier = try #require(store.terminalReplayBarrierTokensBySurfaceID[surfaceID])

    supersededReport.cancel()
    let cancelledGrid = await supersededReport.value
    #expect(cancelledGrid == nil)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == prearmedBarrier)
    #expect(store.terminalViewportReplayBarrierPendingAckTokensBySurfaceID[surfaceID] == prearmedBarrier)

    // The superseding report carries the surviving barrier and resolves it
    // with the acknowledged resize's authoritative replay.
    let supersedingGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 30)
    #expect(supersedingGrid?.rows == 30)
    let resizeReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 1
    )
    #expect(resizeReplayRequested, "the superseding report must resolve the carried barrier with a replay")
    guard resizeReplayRequested else {
        await router.releaseAllHeld()
        return
    }
    let replayChunk = try #require(await iterator.next())
    #expect(String(data: replayChunk.data, encoding: .utf8) == "superseding-resize-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    await router.releaseAllHeld()
    store.deliverTerminalBytes(Data("live-after-supersede".utf8), surfaceID: surfaceID)
    let liveChunk = try #require(await iterator.next())
    #expect(String(data: liveChunk.data, encoding: .utf8) == "live-after-supersede")
}

@MainActor
@Test func terminalEffectiveGridResizeRetriesEmptyReplacementReplay() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts([
        "cold-replay",
        "initial-viewport-replay",
        "post-empty-retry-replay",
    ])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initialViewportChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    // A recovery replay is in flight when the effective grid changes without
    // a prearm; the fresh resize barrier replaces it.
    await router.holdNextReplayResponses(count: 1)
    store.terminalOutputNeedsReplay(surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterBaseline + 1)

    // The resize's own replay comes back empty. The replaced recovery work
    // was owed, so the empty response must retry instead of clearing the
    // barrier with the recovery lost.
    await router.enqueueEmptyReplayResponses(count: 1)
    await router.setViewportEffectiveGrid(columns: 80, rows: 30)
    let resizedGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    #expect(resizedGrid?.rows == 30)
    let retryRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 3
    )
    #expect(
        retryRequested,
        "an empty replacement replay must retry when the resize barrier replaced owed recovery work"
    )
    guard retryRequested else {
        await router.releaseAllHeld()
        return
    }

    let retryChunk = try #require(await iterator.next())
    #expect(String(data: retryChunk.data, encoding: .utf8) == "post-empty-retry-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: retryChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    await router.releaseAllHeld()
    store.deliverTerminalBytes(Data("live-after-empty-retry".utf8), surfaceID: surfaceID)
    let liveChunk = try #require(await iterator.next())
    #expect(String(data: liveChunk.data, encoding: .utf8) == "live-after-empty-retry")
}

@MainActor
@Test func terminalSameSizeReportReArmsExhaustedResizeBarrier() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts([
        "cold-replay",
        "initial-viewport-replay",
        "rearm-replay",
    ])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initialViewportChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    // The resize replay fails through its whole retry budget (initial + two
    // retries), leaving a preserved barrier with the grid already settled.
    await router.failNextReplay(count: 3)
    let resizedGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 30)
    #expect(resizedGrid?.rows == 30)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterBaseline + 3)
    let droppedAccepted = store.deliverTerminalBytes(
        Data("dropped-behind-exhausted-barrier".utf8),
        surfaceID: surfaceID
    )
    #expect(!droppedAccepted, "output must still be dropped behind the preserved barrier")

    // A same-size geometry reassert must re-arm recovery instead of leaving
    // the surface wedged behind the exhausted barrier forever.
    let reassertedGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 30)
    #expect(reassertedGrid?.rows == 30)
    let rearmRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 4
    )
    #expect(
        rearmRequested,
        "a same-size report must re-arm a replay after the resize barrier exhausted its retries"
    )
    guard rearmRequested else { return }

    let rearmChunk = try #require(await iterator.next())
    #expect(String(data: rearmChunk.data, encoding: .utf8) == "rearm-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: rearmChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.deliverTerminalBytes(Data("live-after-rearm".utf8), surfaceID: surfaceID)
    let liveChunk = try #require(await iterator.next())
    #expect(String(data: liveChunk.data, encoding: .utf8) == "live-after-rearm")
}

@MainActor
@Test func terminalViewportReportCachesGeometryWhileDisconnected() async throws {
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
    let workspaceID = try #require(store.workspaces.first?.id)

    // Dropping the connection clears the generations but deliberately keeps
    // the cached dimensions: geometry seeded between connections must still
    // ride the next connection's piggybacks (the Mac refuses generationless
    // overwrites of generation-carrying pins, so a stale survivor cannot
    // supersede newer geometry).
    let staleKey = MobileTerminalViewportKey(
        workspaceID: workspaceID,
        terminalID: MobileTerminalPreview.ID(rawValue: surfaceID)
    )
    store.reportTerminalViewport(
        workspaceID: workspaceID,
        terminalID: MobileTerminalPreview.ID(rawValue: surfaceID),
        viewportSize: MobileTerminalViewportSize(columns: 80, rows: 48)
    )
    #expect(store.reportedViewportSizesByTerminalKey[staleKey] != nil)
    store.remoteClient = nil
    #expect(store.reportedViewportSizesByTerminalKey[staleKey] != nil)
    #expect(store.viewportReportGenerationsBySurfaceID[surfaceID] == nil)

    // A geometry report while the Mac connection is down must still update
    // the local dimension cache that replays and piggybacks size against;
    // only the RPC is skipped.
    let offlineGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 90, rows: 33)
    #expect(offlineGrid == nil)
    let key = MobileTerminalViewportKey(
        workspaceID: workspaceID,
        terminalID: MobileTerminalPreview.ID(rawValue: surfaceID)
    )
    #expect(store.reportedViewportSizesByTerminalKey[key]?.columns == 90)
    #expect(store.reportedViewportSizesByTerminalKey[key]?.rows == 33)
    // The offline report must also consume a generation so the cached
    // dimensions never ride a piggyback generationless after reconnect.
    #expect(store.viewportReportGenerationsBySurfaceID[surfaceID] != nil)
}

@MainActor
@Test func terminalReplayRequestRejectsStaleBarrierToken() async throws {
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

    let staleToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    let currentToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    let replayCountBeforeStaleRequest = await router.count(of: "mobile.terminal.replay")
    store.requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: staleToken)

    let staleReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountBeforeStaleRequest + 1,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!staleReplayRequested, "a stale barrier token must not start or cancel replay")
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == currentToken)
}

@MainActor
@Test func terminalViewportFailedReportDoesNotConfirmNaturalGridForRetry() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts([
        "cold-replay",
        "initial-viewport-replay",
        "failed-reset-replay",
        "retry-resize-replay",
    ])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initialViewportChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    await router.emptyNextViewportResponses()
    await router.holdViewportRequest(number: 2)
    let failedReport = Task {
        await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 30)
    }
    await router.waitForCount(of: "mobile.terminal.viewport", atLeast: 2)
    let resetStreamToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])
    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: resetStreamToken)
    await router.releaseAllHeld()
    let failedGrid = await failedReport.value
    #expect(failedGrid == nil)
    let resetReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterBaseline + 1
    )
    #expect(resetReplayRequested, "a reset during a failed pre-ACK viewport report must still replay")
    let resetReplayChunk = try #require(await iterator.next())
    #expect(String(data: resetReplayChunk.data, encoding: .utf8) == "failed-reset-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: resetReplayChunk.streamToken)
    let replayCountAfterFailedReset = await router.count(of: "mobile.terminal.replay")

    await router.holdViewportRequest(number: 3)
    let retryReport = Task {
        await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 30)
    }
    await router.waitForCount(of: "mobile.terminal.viewport", atLeast: 3)

    let staleAccepted = store.deliverTerminalBytes(
        Data("stale-during-retry".utf8),
        surfaceID: surfaceID
    )
    #expect(!staleAccepted, "a same-size retry after a failed report must still prearm a barrier")

    await router.releaseAllHeld()
    let retryGrid = await retryReport.value
    #expect(retryGrid?.rows == 30)
    let replayAfterRetry = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterFailedReset + 1
    )
    #expect(replayAfterRetry, "the successful retry must request replay for the new effective grid")
    let replayChunk = try #require(await iterator.next())
    #expect(String(data: replayChunk.data, encoding: .utf8) == "retry-resize-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
}

@MainActor
@Test func terminalViewportDetachKeepsGenerationTombstoneForStaleAcks() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "initial-viewport-replay"])
    try await mountOutputAndReportViewport(store: store, router: router, surfaceID: surfaceID)

    let clearSent = await router.waitForCount(of: "mobile.terminal.viewport", atLeast: 2)
    #expect(clearSent)
    #expect(store.viewportReportGenerationsBySurfaceID[surfaceID] == 2)
}

@MainActor
private func mountOutputAndReportViewport(
    store: MobileShellComposite,
    router: LivenessHostRouter,
    surfaceID: String
) async throws {
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initialViewportChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    #expect(store.viewportReportGenerationsBySurfaceID[surfaceID] == 1)
}
