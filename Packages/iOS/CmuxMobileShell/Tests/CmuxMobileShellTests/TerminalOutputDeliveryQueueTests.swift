import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@Test func terminalOutputQueueDeliversFirstChunkImmediately() {
    var queue = TerminalOutputDeliveryQueue()
    let first = TerminalOutputDelivery(bytes: Data("first".utf8), replaceable: false)

    #expect(queue.enqueue(first) == first)
    #expect(queue.pendingCount == 0)
}

@Test func terminalOutputQueueIgnoresCompletionWhenNothingIsInFlight() {
    var queue = TerminalOutputDeliveryQueue()

    #expect(queue.completeInFlight() == nil)
    #expect(queue.isIdle)
}

@MainActor
@Test func staleStreamAckDoesNotAdvanceReplacementOutputQueue() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"

    var oldIterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    store.deliverTerminalBytes(Data("old-first".utf8), surfaceID: surfaceID)
    let oldChunk = try #require(await oldIterator.next())

    var currentIterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    store.deliverTerminalBytes(Data("new-first".utf8), surfaceID: surfaceID)
    let currentChunk = try #require(await currentIterator.next())
    store.deliverTerminalBytes(Data("new-second".utf8), surfaceID: surfaceID)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: oldChunk.streamToken)

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount == 1)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: currentChunk.streamToken)
    let secondChunk = try #require(await currentIterator.next())
    #expect(String(decoding: secondChunk.data, as: UTF8.self) == "new-second")
}

@Test func terminalOutputQueueCoalescesReplaceableViewportFramesBehindBackpressure() {
    var queue = TerminalOutputDeliveryQueue()
    let inFlight = TerminalOutputDelivery(bytes: Data("in-flight".utf8), replaceable: false)
    let oldViewport = TerminalOutputDelivery(bytes: Data("old viewport".utf8), replaceable: true)
    let latestViewport = TerminalOutputDelivery(bytes: Data("latest viewport".utf8), replaceable: true)

    #expect(queue.enqueue(inFlight) == inFlight)
    #expect(queue.enqueue(oldViewport) == nil)
    #expect(queue.enqueue(latestViewport) == nil)

    #expect(queue.pendingCount == 1)
    #expect(queue.completeInFlight() == latestViewport)
    #expect(queue.completeInFlight() == nil)
    #expect(queue.isIdle)
}

@Test func terminalOutputQueueCoalescesRenderGridFramesBeforeSynthesizingBytes() throws {
    var queue = TerminalOutputDeliveryQueue()
    let inFlight = TerminalOutputDelivery(bytes: Data("in-flight".utf8), replaceable: false)
    let oldFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        columns: 12,
        rows: 2,
        text: "old\nviewport",
        full: false,
        changedRows: [0, 1]
    )
    let latestFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 2,
        columns: 12,
        rows: 2,
        text: "latest\nviewport",
        full: false,
        changedRows: [0, 1]
    )

    #expect(queue.enqueue(inFlight) == inFlight)
    #expect(queue.enqueue(TerminalOutputDelivery(renderGrid: oldFrame, replaceable: true)) == nil)
    #expect(queue.enqueue(TerminalOutputDelivery(renderGrid: latestFrame, replaceable: true)) == nil)

    let maybeDelivered = queue.completeInFlight()
    let delivered = try #require(maybeDelivered)
    let vt = try #require(String(data: delivered.bytes, encoding: .utf8))
    #expect(vt.contains("latest"))
    #expect(!vt.contains("old"))
}

@Test func terminalOutputQueuePreservesNonreplaceableBarriers() {
    var queue = TerminalOutputDeliveryQueue()
    let inFlight = TerminalOutputDelivery(bytes: Data("in-flight".utf8), replaceable: false)
    let viewport = TerminalOutputDelivery(bytes: Data("viewport".utf8), replaceable: true)
    let rawBytes = TerminalOutputDelivery(bytes: Data("raw".utf8), replaceable: false)
    let laterViewport = TerminalOutputDelivery(bytes: Data("later viewport".utf8), replaceable: true)

    #expect(queue.enqueue(inFlight) == inFlight)
    #expect(queue.enqueue(viewport) == nil)
    #expect(queue.enqueue(rawBytes) == nil)
    #expect(queue.enqueue(laterViewport) == nil)

    #expect(queue.pendingCount == 3)
    #expect(queue.completeInFlight() == viewport)
    #expect(queue.completeInFlight() == rawBytes)
    #expect(queue.completeInFlight() == laterViewport)
    #expect(queue.completeInFlight() == nil)
}

@Test func terminalOutputQueueDrainsRawFallbackBacklogInOrder() {
    var queue = TerminalOutputDeliveryQueue()
    let inFlight = TerminalOutputDelivery(bytes: Data("in-flight".utf8), replaceable: false)

    #expect(queue.enqueue(inFlight) == inFlight)
    for index in 0..<128 {
        let delivery = TerminalOutputDelivery(bytes: Data("raw-\(index)".utf8), replaceable: false)
        #expect(queue.enqueue(delivery) == nil)
    }

    #expect(queue.pendingCount == 128)
    for index in 0..<128 {
        let expected = TerminalOutputDelivery(bytes: Data("raw-\(index)".utf8), replaceable: false)
        #expect(queue.completeInFlight() == expected)
    }
    #expect(queue.completeInFlight() == nil)
    #expect(queue.isIdle)
}

// Regression for https://github.com/manaflow-ai/cmux/issues/6358: switching a
// workspace away and quickly back remounts the same terminal surface. Mount 2
// installs the live output sink, but mount 1's stream teardown is deferred onto
// the main actor. If that stale teardown unregisters unconditionally it rips out
// mount 2's freshly-installed sink, leaving the remounted surface showing stale /
// leftover content because it can no longer receive frames. The teardown must
// only fire when it still owns the live registration.
@MainActor
@Test func remountedSurfaceSinkSurvivesStaleStreamTeardown() async {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"

    // Mount 1: selecting the workspace attaches and consumes an output sink.
    let staleMount = OutputCollector()
    staleMount.mount(store: store, surfaceID: surfaceID)
    for _ in 0..<100 where store.terminalOutputStreamTokensBySurfaceID[surfaceID] == nil {
        await Task.yield()
    }
    let staleToken = store.terminalOutputStreamTokensBySurfaceID[surfaceID]

    // Quick switch away-and-back remounts the SAME surface; mount 2 registers a
    // fresh sink (new stream token) and begins consuming the live output.
    let liveMount = OutputCollector()
    liveMount.mount(store: store, surfaceID: surfaceID)
    for _ in 0..<100 where store.terminalOutputStreamTokensBySurfaceID[surfaceID] == staleToken {
        await Task.yield()
    }

    // Mount 1 goes away: its stream terminates and schedules the deferred
    // main-actor teardown. Drain it before delivering so a regression (the
    // unconditional teardown) has already unregistered mount 2 by delivery time.
    staleMount.unmount()
    for _ in 0..<100 { await Task.yield() }

    // Behavior: a frame delivered after the stale teardown must actually reach the
    // remounted sink. Without the lifetime-token guard the teardown unregisters
    // mount 2 and this delivery is dropped — the user-visible "stranded on stale
    // content" bug. Bounded poll so a regression fails fast instead of hanging.
    store.deliverTerminalBytes(Data("live".utf8), surfaceID: surfaceID)
    for _ in 0..<500 where !liveMount.lines.contains("live") {
        await Task.yield()
    }
    #expect(liveMount.lines.contains("live"))

    liveMount.unmount()
}

@Test func renderGridViewportPatchIsReplaceableOnlyWhenEveryRowIsCleared() throws {
    let fullFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        columns: 12,
        rows: 3,
        text: "a\nb\nc"
    )
    let fullViewportDelta = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 2,
        columns: 12,
        rows: 3,
        text: "d\ne\nf",
        full: false,
        changedRows: [0, 1, 2]
    )
    let partialDelta = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 3,
        columns: 12,
        rows: 3,
        text: "d\ne\nf",
        full: false,
        changedRows: [1]
    )

    #expect(!fullFrame.isReplaceableViewportPatchForMobileDelivery)
    #expect(fullViewportDelta.isReplaceableViewportPatchForMobileDelivery)
    #expect(!partialDelta.isReplaceableViewportPatchForMobileDelivery)
}
