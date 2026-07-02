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
        "viewport-resync-replay",
        "viewport-resync-follow-up",
    ])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    // The first viewport report after mount establishes the baseline geometry.
    // The cold-attach replay already covers it, so it must not replay again.
    let baselineGrid = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
    #expect(baselineGrid?.columns == 80)
    #expect(baselineGrid?.rows == 48)
    let baselineReplayed = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 2,
        timeoutNanoseconds: 200_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!baselineReplayed, "the baseline viewport report must not trigger a replay")
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

    await router.enqueueReplayTexts(["cold-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 80, rows: 48)
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
