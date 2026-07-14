import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func authoritativeReplayNeedsAppliedSemanticBaselineBeforeClearingBarrier() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let baseline = try authoritativeSemanticFrame(seq: 8, revision: 1, text: "baseline")
    await router.enqueueReplayRenderGrid(baseline)
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let streams = store.authoritativeTerminalOutputStreams(surfaceID: "live-terminal")
    var visual = streams.visual.makeAsyncIterator()
    var semantic = streams.semantic.makeAsyncIterator()

    let visualValue = await visual.next()
    let visualBaseline = try #require(visualValue)
    let semanticValue = await semantic.next()
    let semanticBaseline = try #require(semanticValue)
    #expect(visualBaseline.renderGrid == baseline)
    #expect(visualBaseline.data.isEmpty)
    #expect(semanticBaseline.data == baseline.vtReplacementBytes())
    #expect(store.terminalReplayBarrierTokensBySurfaceID["live-terminal"] != nil)

    store.terminalOutputDidProcess(
        surfaceID: "live-terminal",
        streamToken: visualBaseline.streamToken,
        disposition: .ignored
    )
    #expect(store.terminalReplayBarrierTokensBySurfaceID["live-terminal"] != nil)

    store.terminalSemanticOutputDidProcess(
        surfaceID: "live-terminal",
        streamToken: semanticBaseline.streamToken,
        disposition: .applied
    )
    #expect(store.terminalReplayBarrierTokensBySurfaceID["live-terminal"] == nil)
    #expect(store.terminalSemanticAppliedEndSeqBySurfaceID["live-terminal"] == 8)

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 9,
        text: "fresh-after-ignored"
    ))
    let freshValue = await visual.next()
    let fresh = try #require(freshValue)
    #expect(fresh.renderGrid?.plainRows().first == "fresh-after-ignored")
}

@MainActor
@Test func authoritativeVisualLaneAdvancesWhileSemanticRawIsBackpressured() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let baseline = try authoritativeSemanticFrame(seq: 20, revision: 1, text: "baseline")
    await router.enqueueReplayRenderGrid(baseline)
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let streams = store.authoritativeTerminalOutputStreams(surfaceID: "live-terminal")
    var visual = streams.visual.makeAsyncIterator()
    var semantic = streams.semantic.makeAsyncIterator()

    let visualBaselineValue = await visual.next()
    let visualBaseline = try #require(visualBaselineValue)
    let semanticBaselineValue = await semantic.next()
    let semanticBaseline = try #require(semanticBaselineValue)
    store.terminalOutputDidProcess(
        surfaceID: "live-terminal",
        streamToken: visualBaseline.streamToken,
        disposition: .applied
    )
    store.terminalSemanticOutputDidProcess(
        surfaceID: "live-terminal",
        streamToken: semanticBaseline.streamToken,
        disposition: .applied
    )

    let transport = try #require(box.get())
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: "live-terminal",
        seq: 20,
        text: "exact-raw"
    ))
    let rawValue = await semantic.next()
    let raw = try #require(rawValue)
    #expect(String(decoding: raw.data, as: UTF8.self) == "exact-raw")

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 29,
        text: "pixels-do-not-wait"
    ))
    let liveGridValue = await visual.next()
    let liveGrid = try #require(liveGridValue)
    #expect(liveGrid.renderGrid?.plainRows().first == "pixels-do-not-wait")
    #expect(liveGrid.data.isEmpty)
    #expect(store.terminalSemanticAppliedEndSeqBySurfaceID["live-terminal"] == 20)

    store.terminalSemanticOutputDidProcess(
        surfaceID: "live-terminal",
        streamToken: raw.streamToken,
        disposition: .applied
    )
    #expect(store.terminalSemanticAppliedEndSeqBySurfaceID["live-terminal"] == 29)
}

@MainActor
@Test func authoritativeSemanticRawTrimsOverlapAndGapRotatesOnlySemanticGeneration() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let baseline = try authoritativeSemanticFrame(seq: 50, revision: 1, text: "baseline")
    await router.enqueueReplayRenderGrid(baseline)
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let streams = store.authoritativeTerminalOutputStreams(surfaceID: "live-terminal")
    var visual = streams.visual.makeAsyncIterator()
    var semantic = streams.semantic.makeAsyncIterator()

    let visualBaselineValue = await visual.next()
    let visualBaseline = try #require(visualBaselineValue)
    let semanticBaselineValue = await semantic.next()
    let semanticBaseline = try #require(semanticBaselineValue)
    store.terminalOutputDidProcess(
        surfaceID: "live-terminal",
        streamToken: visualBaseline.streamToken,
        disposition: .applied
    )
    store.terminalSemanticOutputDidProcess(
        surfaceID: "live-terminal",
        streamToken: semanticBaseline.streamToken,
        disposition: .applied
    )

    let transport = try #require(box.get())
    await transport.deliver(try terminalBytesEventFrame(surfaceID: "live-terminal", seq: 50, text: "abc"))
    let firstValue = await semantic.next()
    let first = try #require(firstValue)
    #expect(String(decoding: first.data, as: UTF8.self) == "abc")
    await transport.deliver(try terminalBytesEventFrame(surfaceID: "live-terminal", seq: 52, text: "cde"))
    let overlapScheduled = try await pollUntil {
        store.terminalSemanticScheduledEndSeqBySurfaceID["live-terminal"] == 55
    }
    #expect(overlapScheduled)
    store.terminalSemanticOutputDidProcess(
        surfaceID: "live-terminal",
        streamToken: first.streamToken,
        disposition: .applied
    )
    let overlapValue = await semantic.next()
    let overlap = try #require(overlapValue)
    #expect(String(decoding: overlap.data, as: UTF8.self) == "de")
    store.terminalSemanticOutputDidProcess(
        surfaceID: "live-terminal",
        streamToken: overlap.streamToken,
        disposition: .applied
    )

    let oldSemanticToken = overlap.streamToken
    let visualToken = visualBaseline.streamToken
    let replayCountBeforeGap = await router.count(of: "mobile.terminal.replay")
    await router.holdNextReplayResponses()
    await transport.deliver(try terminalBytesEventFrame(surfaceID: "live-terminal", seq: 60, text: "gap"))
    let replayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountBeforeGap
    }
    #expect(replayRequested)
    #expect(store.terminalSemanticOutputStreamTokensBySurfaceID["live-terminal"] != oldSemanticToken)
    #expect(store.terminalOutputStreamTokensBySurfaceID["live-terminal"] == visualToken)
    #expect(store.terminalSemanticScheduledEndSeqBySurfaceID["live-terminal"] == nil)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 63,
        text: "pixels-survive-gap"
    ))
    let liveGridValue = await visual.next()
    let liveGrid = try #require(liveGridValue)
    #expect(liveGrid.renderGrid?.plainRows().first == "pixels-survive-gap")
    await router.releaseAllHeld()
}

@MainActor
@Test func authoritativeRemountFinishesBothOldLanesWithoutUnregisteringReplacement() async {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    let oldStreams = store.authoritativeTerminalOutputStreams(surfaceID: surfaceID)
    var oldVisual = oldStreams.visual.makeAsyncIterator()
    var oldSemantic = oldStreams.semantic.makeAsyncIterator()
    let oldMountToken = store.terminalOutputMountTokensBySurfaceID[surfaceID]

    let replacement = store.authoritativeTerminalOutputStreams(surfaceID: surfaceID)
    let replacementMountToken = store.terminalOutputMountTokensBySurfaceID[surfaceID]

    #expect(await oldVisual.next() == nil)
    #expect(await oldSemantic.next() == nil)
    await Task.yield()
    #expect(replacementMountToken != oldMountToken)
    #expect(store.terminalOutputMountTokensBySurfaceID[surfaceID] == replacementMountToken)
    #expect(store.terminalByteContinuationsBySurfaceID[surfaceID] != nil)
    #expect(store.terminalSemanticByteContinuationsBySurfaceID[surfaceID] != nil)
    _ = replacement
}

@MainActor
@Test func newerPixelFrameCannotMakeOlderSemanticReplayBaselineStale() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let baseline = try authoritativeSemanticFrame(seq: 100, revision: 1, text: "semantic-baseline")
    await router.enqueueReplayRenderGrid(baseline)
    await router.holdNextReplayResponses()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let streams = store.authoritativeTerminalOutputStreams(surfaceID: "live-terminal")
    var visual = streams.visual.makeAsyncIterator()
    var semantic = streams.semantic.makeAsyncIterator()
    let replayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= 1
    }
    #expect(replayRequested)

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 110,
        text: "newer-pixels"
    ))
    let pixelValue = await visual.next()
    let pixel = try #require(pixelValue)
    #expect(pixel.renderGrid?.stateSeq == 110)
    store.terminalOutputDidProcess(
        surfaceID: "live-terminal",
        streamToken: pixel.streamToken,
        disposition: .applied
    )

    await router.releaseAllHeld()
    let semanticValue = await semantic.next()
    let semanticBaseline = try #require(semanticValue)
    #expect(semanticBaseline.kind == .baseline)
    #expect(semanticBaseline.endSeq == 100)
    #expect(semanticBaseline.data == baseline.vtReplacementBytes())
}

private func authoritativeSemanticFrame(
    seq: UInt64,
    revision: UInt64,
    text: String
) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: "live-terminal",
        stateSeq: seq,
        renderRevision: revision,
        columns: 24,
        rows: 2,
        cursor: .init(row: 0, column: text.count),
        full: true,
        rowSpans: [.init(row: 0, column: 0, text: text)],
        scrollbackRows: 1,
        scrollbackSpans: [.init(row: 0, column: 0, text: "history")]
    )
}
