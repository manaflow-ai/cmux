import CMUXMobileCore
import CmuxMobileShellModel
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

@MainActor
@Test func liveRenderGridWaitsBehindInFlightReplay() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    let streamToken = UUID()
    let stream = AsyncStream<MobileTerminalOutputChunk> { continuation in
        store.terminalByteContinuationsBySurfaceID[surfaceID] = continuation
        store.terminalOutputStreamTokensBySurfaceID[surfaceID] = streamToken
        store.terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
    }
    _ = stream

    store.debugMarkTerminalReplayInFlightForTesting(surfaceID: surfaceID)
    let liveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 2,
        columns: 16,
        rows: 2,
        text: "live\nviewport",
        full: false,
        changedRows: [0, 1]
    )

    store.deliverAuthoritativeTerminalRenderGrid(liveFrame, source: "event")

    #expect(
        store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true,
        "live deltas must wait behind the cold replay so scrollback is seeded before the viewport starts updating"
    )

    let replayFrame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 1,
        columns: 16,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "vp0"),
            .init(row: 1, column: 0, text: "vp1"),
        ],
        scrollbackRows: 2,
        scrollbackSpans: [
            .init(row: 0, column: 0, text: "old0"),
            .init(row: 1, column: 0, text: "old1"),
        ]
    )
    store.debugFinishTerminalReplayForTesting(surfaceID: surfaceID, replayFrame: replayFrame)

    let queueAfterReplay = try #require(store.terminalOutputQueuesBySurfaceID[surfaceID])
    #expect(queueAfterReplay.isIdle == false, "the replay should be the in-flight delivery")
    #expect(queueAfterReplay.pendingCount == 1, "the live frame should be queued behind the replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: streamToken)

    let queueAfterReplayAck = try #require(store.terminalOutputQueuesBySurfaceID[surfaceID])
    #expect(queueAfterReplayAck.isIdle == false, "acking the replay should advance the buffered live frame")
    #expect(queueAfterReplayAck.pendingCount == 0)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: streamToken)
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
}

@MainActor
@Test func staleReplayFinishCannotFlushNewReplayBuffer() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    let streamToken = UUID()
    let stream = AsyncStream<MobileTerminalOutputChunk> { continuation in
        store.terminalByteContinuationsBySurfaceID[surfaceID] = continuation
        store.terminalOutputStreamTokensBySurfaceID[surfaceID] = streamToken
        store.terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
    }
    _ = stream

    let staleReplayID = store.debugMarkTerminalReplayInFlightForTesting(surfaceID: surfaceID)
    let staleLiveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 2,
        columns: 16,
        rows: 2,
        text: "stale\nlive",
        full: false,
        changedRows: [0, 1]
    )
    store.deliverAuthoritativeTerminalRenderGrid(staleLiveFrame, source: "event")
    store.debugCancelTerminalReplayForTesting(surfaceID: surfaceID)

    let currentReplayID = store.debugMarkTerminalReplayInFlightForTesting(surfaceID: surfaceID)
    let currentLiveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 4,
        columns: 16,
        rows: 2,
        text: "current\nlive",
        full: false,
        changedRows: [0, 1]
    )
    store.deliverAuthoritativeTerminalRenderGrid(currentLiveFrame, source: "event")

    let staleReplayFrame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 1,
        columns: 16,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "old-vp0"),
            .init(row: 1, column: 0, text: "old-vp1"),
        ],
        scrollbackRows: 1,
        scrollbackSpans: [
            .init(row: 0, column: 0, text: "old-scroll"),
        ]
    )
    store.debugFinishTerminalReplayForTesting(
        surfaceID: surfaceID,
        replayID: staleReplayID,
        replayFrame: staleReplayFrame
    )

    #expect(
        store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true,
        "a stale replay must not clear the newer replay barrier or deliver old scrollback"
    )

    let currentReplayFrame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 3,
        columns: 16,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "new-vp0"),
            .init(row: 1, column: 0, text: "new-vp1"),
        ],
        scrollbackRows: 1,
        scrollbackSpans: [
            .init(row: 0, column: 0, text: "new-scroll"),
        ]
    )
    store.debugFinishTerminalReplayForTesting(
        surfaceID: surfaceID,
        replayID: currentReplayID,
        replayFrame: currentReplayFrame
    )

    let queueAfterReplay = try #require(store.terminalOutputQueuesBySurfaceID[surfaceID])
    #expect(queueAfterReplay.isIdle == false)
    #expect(queueAfterReplay.pendingCount == 1)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: streamToken)

    let queueAfterReplayAck = try #require(store.terminalOutputQueuesBySurfaceID[surfaceID])
    #expect(queueAfterReplayAck.isIdle == false)
    #expect(queueAfterReplayAck.pendingCount == 0)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: streamToken)
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
}

@MainActor
@Test func failedReplayDropsBufferedLiveRenderGrid() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    let streamToken = UUID()
    let stream = AsyncStream<MobileTerminalOutputChunk> { continuation in
        store.terminalByteContinuationsBySurfaceID[surfaceID] = continuation
        store.terminalOutputStreamTokensBySurfaceID[surfaceID] = streamToken
        store.terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
    }
    _ = stream

    let replayID = store.debugMarkTerminalReplayInFlightForTesting(surfaceID: surfaceID)
    let liveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 2,
        columns: 16,
        rows: 2,
        text: "live\nviewport",
        full: false,
        changedRows: [0, 1]
    )

    store.deliverAuthoritativeTerminalRenderGrid(liveFrame, source: "event")
    store.debugFailTerminalReplayForTesting(surfaceID: surfaceID, replayID: replayID)

    #expect(
        store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true,
        "a failed replay must not flush live render-grid frames before scrollback has been seeded"
    )
    #expect(store.terminalReplayIDsInFlightBySurfaceID[surfaceID] == nil)
    #expect(store.terminalRenderGridFramesBufferedDuringReplayBySurfaceID[surfaceID] == nil)
}

@MainActor
@Test func replayOverflowRequiresFullFrameBeforeLiveDeltasResume() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    let streamToken = UUID()
    let stream = AsyncStream<MobileTerminalOutputChunk> { continuation in
        store.terminalByteContinuationsBySurfaceID[surfaceID] = continuation
        store.terminalOutputStreamTokensBySurfaceID[surfaceID] = streamToken
        store.terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
    }
    _ = stream

    store.debugMarkTerminalReplayInFlightForTesting(surfaceID: surfaceID)
    let liveFrameCount = MobileShellComposite.maxRenderGridFramesBufferedDuringReplay + 2
    for index in 0..<liveFrameCount {
        let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: surfaceID,
            stateSeq: UInt64(index + 2),
            columns: 16,
            rows: 2,
            text: "live \(index)\nviewport",
            full: false,
            changedRows: [0, 1]
        )
        store.deliverAuthoritativeTerminalRenderGrid(frame, source: "event")
    }

    let replayFrame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: 1,
        columns: 16,
        rows: 2,
        rowSpans: [
            .init(row: 0, column: 0, text: "replay-vp0"),
            .init(row: 1, column: 0, text: "replay-vp1"),
        ],
        scrollbackRows: 1,
        scrollbackSpans: [
            .init(row: 0, column: 0, text: "replay-scroll"),
        ]
    )
    store.debugFinishTerminalReplayForTesting(surfaceID: surfaceID, replayFrame: replayFrame)

    let queueAfterReplay = try #require(store.terminalOutputQueuesBySurfaceID[surfaceID])
    #expect(queueAfterReplay.isIdle == false)
    #expect(
        queueAfterReplay.pendingCount == 0,
        "overflow drops part of a render-grid delta chain, so the retained live tail must be discarded instead of replayed on top of a gap"
    )
    #expect(store.terminalReplayIDsInFlightBySurfaceID[surfaceID] == nil)
    #expect(store.terminalRenderGridFramesBufferedDuringReplayBySurfaceID[surfaceID] == nil)
    #expect(store.terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: streamToken)

    let queueAfterReplayAck = try #require(store.terminalOutputQueuesBySurfaceID[surfaceID])
    #expect(queueAfterReplayAck.isIdle == true)
    #expect(queueAfterReplayAck.pendingCount == 0)

    let partialAfterGap = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: UInt64(liveFrameCount + 2),
        columns: 16,
        rows: 2,
        text: "partial after gap\nviewport",
        full: false,
        changedRows: [0]
    )
    store.deliverAuthoritativeTerminalRenderGrid(partialAfterGap, source: "event")
    #expect(
        store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true,
        "a partial delta after an overflow gap must not apply until a full frame or replay restores continuity"
    )
    #expect(store.terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID))

    let fullAfterGap = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: UInt64(liveFrameCount + 3),
        columns: 16,
        rows: 2,
        text: "full after gap\nviewport",
        full: true
    )
    store.deliverAuthoritativeTerminalRenderGrid(fullAfterGap, source: "event")
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == false)
    #expect(store.terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID) == false)
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
