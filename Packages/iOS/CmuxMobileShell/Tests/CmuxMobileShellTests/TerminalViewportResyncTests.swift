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

    await router.enqueueReplayTexts(["cold-replay", "initial-viewport-replay", "retry-resize-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    let initialViewportChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: initialViewportChunk.streamToken)
    let replayCountAfterBaseline = await router.count(of: "mobile.terminal.replay")

    await router.emptyNextViewportResponses()
    let failedGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 30)
    #expect(failedGrid == nil)

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
        atLeast: replayCountAfterBaseline + 1
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
