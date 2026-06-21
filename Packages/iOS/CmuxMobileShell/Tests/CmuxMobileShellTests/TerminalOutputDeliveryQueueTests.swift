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
@Test func initialReplayBasePrecedesDeferredLiveRenderGrid() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    store.debugBeginInitialTerminalReplayForTesting(surfaceID: surfaceID)

    let liveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 20,
        columns: 16,
        rows: 4,
        text: "live-after",
        full: false,
        changedRows: [0, 1, 2, 3]
    )
    let liveEnvelope = try MobileTerminalRenderGridEnvelope.viewportDelta(liveFrame)
    store.debugDeliverLiveRenderGridForTesting(liveEnvelope)
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)

    var replayFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 10,
        columns: 16,
        rows: 4,
        text: "replay-base"
    )
    replayFrame.scrollbackRows = 123
    let replayEnvelope = try MobileTerminalRenderGridEnvelope.snapshot(replayFrame)
    store.debugDeliverInitialTerminalReplayForTesting(replayEnvelope, surfaceID: surfaceID)

    let replayChunk = try #require(await iterator.next())
    #expect(replayChunk.scrollbackRows == 123)
    switch replayChunk.payload {
    case .bytes:
        Issue.record("render-grid replay was downgraded to bytes before the surface boundary")
    case .renderGrid(let envelope):
        #expect(envelope == replayEnvelope)
    }
    #expect(String(decoding: replayChunk.data, as: UTF8.self).contains("replay-base"))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)

    let liveChunk = try #require(await iterator.next())
    #expect(liveChunk.scrollbackRows == nil)
    switch liveChunk.payload {
    case .bytes:
        Issue.record("live render-grid delta was downgraded to bytes before the surface boundary")
    case .renderGrid(let envelope):
        #expect(envelope == liveEnvelope)
    }
    #expect(String(decoding: liveChunk.data, as: UTF8.self).contains("live-after"))
}

@Test func terminalRenderSessionDropsBufferedLiveDeltasCoveredBySnapshotSequence() throws {
    let surfaceID = "terminal"
    var session = TerminalRenderSession()
    session.beginSnapshot()

    let staleLiveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 20,
        columns: 16,
        rows: 2,
        text: "stale-live",
        full: false,
        changedRows: [0, 1]
    )
    let freshLiveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 40,
        columns: 16,
        rows: 2,
        text: "fresh-live",
        full: false,
        changedRows: [0, 1]
    )
    let snapshotFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 30,
        columns: 16,
        rows: 2,
        text: "snapshot"
    )

    #expect(session.receiveLive(try .viewportDelta(staleLiveFrame)).isEmpty)
    #expect(session.receiveLive(try .viewportDelta(freshLiveFrame)).isEmpty)

    let delivered = session.receiveSnapshot(try .snapshot(snapshotFrame))

    #expect(delivered.map(\.frame.stateSeq) == [30, 40])
}

@Test func terminalRenderSessionBoundsLiveBufferWhileAwaitingSnapshot() throws {
    let surfaceID = "terminal"
    var session = TerminalRenderSession()
    session.beginSnapshot()

    for seq in 1...100 {
        let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: surfaceID,
            stateSeq: UInt64(seq),
            columns: 16,
            rows: 2,
            text: "live-\(seq)",
            full: false,
            changedRows: [0]
        )
        #expect(session.receiveLive(try .viewportDelta(frame)).isEmpty)
    }

    #expect(session.bufferedLiveCount == 64)

    let snapshotFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 90,
        columns: 16,
        rows: 2,
        text: "snapshot"
    )
    let delivered = session.receiveSnapshot(try .snapshot(snapshotFrame))

    #expect(delivered.map(\.frame.stateSeq) == [90] + Array(91...100))
}

@Test func terminalRenderSessionCoalescesReplaceableLiveDeltaWhileAwaitingSnapshot() throws {
    let surfaceID = "terminal"
    var session = TerminalRenderSession()
    session.beginSnapshot()

    let partial = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 10,
        columns: 16,
        rows: 2,
        text: "partial",
        full: false,
        changedRows: [0]
    )
    var replaceable = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 20,
        columns: 16,
        rows: 2,
        text: "replaceable",
        full: false,
        changedRows: [0, 1]
    )
    replaceable.clearedRows = [0, 1]

    #expect(session.receiveLive(try .viewportDelta(partial)).isEmpty)
    #expect(session.receiveLive(try .viewportDelta(replaceable)).isEmpty)
    #expect(session.bufferedLiveCount == 1)

    let snapshotFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 15,
        columns: 16,
        rows: 2,
        text: "snapshot"
    )
    let delivered = session.receiveSnapshot(try .snapshot(snapshotFrame))

    #expect(delivered.map(\.frame.stateSeq) == [15, 20])
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
    let oldEnvelope = try MobileTerminalRenderGridEnvelope.viewportDelta(oldFrame)
    let latestEnvelope = try MobileTerminalRenderGridEnvelope.viewportDelta(latestFrame)

    #expect(queue.enqueue(TerminalOutputDelivery(renderGrid: oldEnvelope, replaceable: true)) == nil)
    #expect(queue.enqueue(TerminalOutputDelivery(renderGrid: latestEnvelope, replaceable: true)) == nil)

    let maybeDelivered = queue.completeInFlight()
    let delivered = try #require(maybeDelivered)
    let vt = try #require(String(data: delivered.chunk(streamToken: UUID()).data, encoding: .utf8))
    #expect(vt.contains("latest"))
    #expect(!vt.contains("old"))
}

@Test func terminalOutputDeliveryCarriesRenderGridMetadata() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal",
        stateSeq: 1,
        columns: 12,
        rows: 2,
        full: true,
        rowSpans: [],
        activeScreen: .primary,
        scrollbackRows: 42
    )
    let deltaFrame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal",
        stateSeq: 2,
        columns: 12,
        rows: 2,
        full: false,
        rowSpans: [],
        activeScreen: .primary,
        scrollbackRows: 42
    )
    let envelope = try MobileTerminalRenderGridEnvelope.snapshot(frame)
    let deltaEnvelope = try MobileTerminalRenderGridEnvelope.viewportDelta(deltaFrame)
    let delivery = TerminalOutputDelivery(renderGrid: envelope, replaceable: false)
    let deltaDelivery = TerminalOutputDelivery(renderGrid: deltaEnvelope, replaceable: false)
    let rawDelivery = TerminalOutputDelivery(bytes: Data("raw".utf8), replaceable: false)
    let deliveryChunk = delivery.chunk(streamToken: UUID())
    let deltaChunk = deltaDelivery.chunk(streamToken: UUID())
    let rawChunk = rawDelivery.chunk(streamToken: UUID())

    #expect(deliveryChunk.activeScreen == MobileTerminalRenderGridFrame.Screen.primary)
    #expect(deliveryChunk.scrollbackRows == 42)
    #expect(deliveryChunk.replayColumns == 12)
    #expect(deliveryChunk.replayRows == 2)
    #expect(deltaChunk.scrollbackRows == nil)
    #expect(deltaChunk.replayColumns == nil)
    #expect(deltaChunk.replayRows == nil)
    #expect(rawChunk.activeScreen == nil)
    #expect(rawChunk.scrollbackRows == nil)
    #expect(rawChunk.replayColumns == nil)
    #expect(rawChunk.replayRows == nil)
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

@Test func viewportDeltaEnvelopeIsReplaceableOnlyWhenEveryRowIsCleared() throws {
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

    let snapshot = try MobileTerminalRenderGridEnvelope.snapshot(fullFrame)
    let fullDelta = try MobileTerminalRenderGridEnvelope.viewportDelta(fullViewportDelta)
    let partial = try MobileTerminalRenderGridEnvelope.viewportDelta(partialDelta)

    #expect(!snapshot.isReplaceableViewportDelta)
    #expect(fullDelta.isReplaceableViewportDelta)
    #expect(!partial.isReplaceableViewportDelta)
}

@Test func viewportDeltaEnvelopeRejectsFullFramesInsteadOfRewritingThem() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        columns: 12,
        rows: 3,
        text: "a\nb\nc",
        full: true
    )

    #expect(throws: MobileTerminalRenderGridEnvelope.ValidationError.viewportDeltaRequiresDeltaFrame) {
        try MobileTerminalRenderGridEnvelope.viewportDelta(frame)
    }
}

@Test func snapshotEnvelopeIsTheOnlyHistoryOwningRenderGridDelivery() throws {
    let primaryWithScrollback = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal",
        stateSeq: 1,
        columns: 12,
        rows: 2,
        full: true,
        rowSpans: [],
        activeScreen: .primary,
        scrollbackRows: 8,
        scrollbackSpans: []
    )
    let viewportDelta = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 2,
        columns: 12,
        rows: 2,
        text: "delta",
        full: false,
        changedRows: [0, 1]
    )

    let snapshot = try MobileTerminalRenderGridEnvelope.snapshot(primaryWithScrollback)
    let delta = try MobileTerminalRenderGridEnvelope.viewportDelta(viewportDelta)

    #expect(snapshot.ownsScrollback)
    #expect(snapshot.scrollbackRowsForLocalMirror == 8)
    #expect(snapshot.replayGrid?.columns == 12)
    #expect(snapshot.replayGrid?.rows == 2)
    #expect(!delta.ownsScrollback)
    #expect(delta.scrollbackRowsForLocalMirror == nil)
    #expect(delta.replayGrid == nil)
}
