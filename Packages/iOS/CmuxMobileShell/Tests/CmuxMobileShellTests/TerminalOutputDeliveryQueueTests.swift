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
@Test func renderGridTransportDropsRawBytesBeforeSurfaceDelivery() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"

    _ = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    store.deliverTerminalBytes(Data("legacy bytes must not clear semantic snapshot".utf8), surfaceID: surfaceID)

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
}

@MainActor
@Test func renderGridTransportInputSeqBehindWaitsForRenderGridEvent() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"

    _ = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    store.debugSetTerminalEventListenerActiveForTesting(true)

    store.debugHandleTerminalInputResponseForTesting(terminalSeq: 42, surfaceID: surfaceID)

    #expect(store.debugPendingTerminalOutputSeqForTesting(surfaceID: surfaceID) == 42)
}

@MainActor
@Test func staleStreamAckDoesNotAdvanceReplacementOutputQueue() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"

    var oldIterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    store.deliverTerminalRenderGrid(try testRenderGridEnvelope(surfaceID: surfaceID, seq: 1, text: "old-first"), surfaceID: surfaceID)
    let oldChunk = try #require(await oldIterator.next())

    var currentIterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    store.deliverTerminalRenderGrid(try testRenderGridEnvelope(surfaceID: surfaceID, seq: 2, text: "new-first"), surfaceID: surfaceID)
    let currentChunk = try #require(await currentIterator.next())
    store.deliverTerminalRenderGrid(try testRenderGridEnvelope(surfaceID: surfaceID, seq: 3, text: "new-second"), surfaceID: surfaceID)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: oldChunk.streamToken)

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount == 1)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: currentChunk.streamToken)
    let secondChunk = try #require(await currentIterator.next())
    #expect(String(decoding: secondChunk.data, as: UTF8.self).contains("new-second"))
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

@MainActor
@Test func missingInitialRenderGridReplayKeepsLiveDeltasBlockedUntilSnapshot() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    store.debugMarkRenderGridCapabilityForTesting()
    store.debugBeginInitialTerminalReplayForTesting(surfaceID: surfaceID)

    store.debugFailInitialTerminalRenderGridReplayForTesting(surfaceID: surfaceID, replaySeq: 10)

    let liveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 11,
        columns: 16,
        rows: 4,
        text: "partial-live-without-base",
        full: false,
        changedRows: [0]
    )
    store.debugDeliverLiveRenderGridForTesting(try .viewportDelta(liveFrame))

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    #expect(store.debugTerminalRenderNeedsSnapshotReplayForTesting(surfaceID: surfaceID))

    let replayFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 12,
        columns: 16,
        rows: 4,
        text: "real-replay-base"
    )
    let replayEnvelope = try MobileTerminalRenderGridEnvelope.snapshot(replayFrame)
    store.debugBeginInitialTerminalReplayForTesting(surfaceID: surfaceID)
    store.debugDeliverInitialTerminalReplayForTesting(replayEnvelope, surfaceID: surfaceID)

    let replayChunk = try #require(await iterator.next())
    switch replayChunk.payload {
    case .bytes:
        Issue.record("render-grid replay was downgraded to bytes before the surface boundary")
    case .renderGrid(let envelope):
        #expect(envelope == replayEnvelope)
    }
    #expect(String(decoding: replayChunk.data, as: UTF8.self).contains("real-replay-base"))
}

@MainActor
@Test func nonSnapshotReplayEnvelopeDoesNotUnblockLiveDeltas() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    store.debugMarkRenderGridCapabilityForTesting()
    store.debugBeginInitialTerminalReplayForTesting(surfaceID: surfaceID)

    let deltaFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 10,
        columns: 16,
        rows: 4,
        text: "not-a-snapshot",
        full: false,
        changedRows: [0, 1, 2, 3]
    )
    store.debugDeliverInitialTerminalReplayForTesting(try .viewportDelta(deltaFrame), surfaceID: surfaceID)

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)

    let liveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 11,
        columns: 16,
        rows: 4,
        text: "live-still-blocked",
        full: false,
        changedRows: [0, 1, 2, 3]
    )
    store.debugDeliverLiveRenderGridForTesting(try .viewportDelta(liveFrame))

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)

    let snapshotFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 12,
        columns: 16,
        rows: 4,
        text: "real-snapshot"
    )
    let snapshotEnvelope = try MobileTerminalRenderGridEnvelope.snapshot(snapshotFrame)
    store.debugDeliverInitialTerminalReplayForTesting(snapshotEnvelope, surfaceID: surfaceID)

    let replayChunk = try #require(await iterator.next())
    switch replayChunk.payload {
    case .bytes:
        Issue.record("render-grid replay was downgraded to bytes before the surface boundary")
    case .renderGrid(let envelope):
        #expect(envelope == snapshotEnvelope)
    }
    #expect(String(decoding: replayChunk.data, as: UTF8.self).contains("real-snapshot"))
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

@Test func terminalRenderSessionDropsBufferedViewportDeltaAtSnapshotSequence() throws {
    let surfaceID = "terminal"
    var session = TerminalRenderSession()
    session.beginSnapshot()

    let liveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 30,
        columns: 16,
        rows: 2,
        text: "snapshot",
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

    #expect(session.receiveLive(try .viewportDelta(liveFrame)).isEmpty)

    let delivered = session.receiveSnapshot(try .snapshot(snapshotFrame))

    #expect(delivered.map(\.frame.stateSeq) == [30])
    #expect(delivered.first?.frame.full == true)
}

@Test func terminalRenderSessionDropsLiveViewportDeltaAtCurrentSequence() throws {
    let surfaceID = "terminal"
    var session = TerminalRenderSession()
    let snapshotFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 30,
        columns: 16,
        rows: 2,
        text: "snapshot"
    )
    let liveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 30,
        columns: 16,
        rows: 2,
        text: "snapshot",
        full: false,
        changedRows: [0, 1]
    )

    _ = session.receiveSnapshot(try .snapshot(snapshotFrame))
    let delivered = session.receiveLive(try .viewportDelta(liveFrame))

    #expect(delivered.isEmpty)
}

@Test func terminalRenderSessionDeliversBufferedSameSequenceResizeDelta() throws {
    let surfaceID = "terminal"
    var session = TerminalRenderSession()
    session.beginSnapshot()

    let liveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 30,
        columns: 20,
        rows: 2,
        text: "snapshot",
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

    #expect(session.receiveLive(try .viewportDelta(liveFrame)).isEmpty)

    let delivered = session.receiveSnapshot(try .snapshot(snapshotFrame))

    #expect(delivered.map(\.frame.stateSeq) == [30, 30])
    #expect(delivered.last?.frame.columns == 20)
}

@Test func terminalRenderSessionDeliversLiveSameSequenceRenderChange() throws {
    let surfaceID = "terminal"
    var session = TerminalRenderSession()
    let snapshotFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 30,
        columns: 16,
        rows: 2,
        text: "snapshot"
    )
    let liveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 30,
        columns: 16,
        rows: 2,
        text: "repaint",
        full: false,
        changedRows: [0, 1]
    )

    _ = session.receiveSnapshot(try .snapshot(snapshotFrame))
    let delivered = session.receiveLive(try .viewportDelta(liveFrame))

    #expect(delivered.map(\.frame.stateSeq) == [30])
    #expect(delivered.first?.frame.rowSignatures() != snapshotFrame.rowSignatures())
}

@Test func terminalRenderSessionDeliversLiveViewportReplacement() throws {
    let surfaceID = "terminal"
    var session = TerminalRenderSession()
    let initialFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 30,
        columns: 16,
        rows: 2,
        text: "initial"
    )
    let resizedFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 31,
        columns: 20,
        rows: 3,
        text: "resized"
    )

    _ = session.receiveSnapshot(try .snapshot(initialFrame))
    let delivered = session.receiveLive(try .viewportReplacement(resizedFrame))

    #expect(delivered.map(\.role) == [.viewportReplacement])
    #expect(delivered.first?.frame.full == true)
    #expect(delivered.first?.frame.columns == 20)
    #expect(delivered.first?.ownsScrollback == false)
}

@Test func terminalRenderSessionInvalidatesSnapshotWhenLiveBufferOverflows() throws {
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

    #expect(session.bufferedLiveCount == 0)
    #expect(session.needsSnapshotReplay)

    let snapshotFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 90,
        columns: 16,
        rows: 2,
        text: "snapshot"
    )
    let delivered = session.receiveSnapshot(try .snapshot(snapshotFrame))

    #expect(delivered.isEmpty)
    #expect(session.needsSnapshotReplay)
}

@Test func terminalRenderSessionInvalidationDropsLiveUntilSnapshotBegins() throws {
    let surfaceID = "terminal"
    var session = TerminalRenderSession()
    let snapshotFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 10,
        columns: 16,
        rows: 2,
        text: "snapshot"
    )
    let liveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 11,
        columns: 16,
        rows: 2,
        text: "live",
        full: false,
        changedRows: [0]
    )

    _ = session.receiveSnapshot(try .snapshot(snapshotFrame))
    session.invalidateSnapshot()

    #expect(session.receiveLive(try .viewportDelta(liveFrame)).isEmpty)
    #expect(session.needsSnapshotReplay)
}

@Test func terminalRenderSessionPreservesFullViewportLiveDeltaWhileAwaitingSnapshot() throws {
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
    var fullViewport = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 20,
        columns: 16,
        rows: 2,
        text: "replaceable",
        full: false,
        changedRows: [0, 1]
    )
    fullViewport.clearedRows = [0, 1]

    #expect(session.receiveLive(try .viewportDelta(partial)).isEmpty)
    #expect(session.receiveLive(try .viewportDelta(fullViewport)).isEmpty)
    #expect(session.bufferedLiveCount == 2)

    let snapshotFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 5,
        columns: 16,
        rows: 2,
        text: "snapshot"
    )
    let delivered = session.receiveSnapshot(try .snapshot(snapshotFrame))

    #expect(delivered.map(\.frame.stateSeq) == [5, 10, 20])
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

@Test func terminalOutputQueuePreservesRenderGridFramesBehindBackpressure() throws {
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

    #expect(queue.enqueue(TerminalOutputDelivery(renderGrid: oldEnvelope, replaceable: false)) == nil)
    #expect(queue.enqueue(TerminalOutputDelivery(renderGrid: latestEnvelope, replaceable: false)) == nil)

    #expect(queue.pendingCount == 2)
    let firstPending = queue.completeInFlight()
    let firstDelivered = try #require(firstPending)
    let firstVT = try #require(String(data: firstDelivered.chunk(streamToken: UUID()).data, encoding: .utf8))
    #expect(firstVT.contains("old"))

    let secondPending = queue.completeInFlight()
    let secondDelivered = try #require(secondPending)
    let secondVT = try #require(String(data: secondDelivered.chunk(streamToken: UUID()).data, encoding: .utf8))
    #expect(secondVT.contains("latest"))
    #expect(queue.completeInFlight() == nil)
}

@Test func terminalOutputQueueCoalescesRenderGridViewportReplacementsBehindBackpressure() throws {
    var queue = TerminalOutputDeliveryQueue()
    let inFlight = TerminalOutputDelivery(bytes: Data("in-flight".utf8), replaceable: false)
    let oldFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        columns: 12,
        rows: 2,
        text: "old\nviewport"
    )
    let latestFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 2,
        columns: 16,
        rows: 2,
        text: "latest\nviewport"
    )
    let oldEnvelope = try MobileTerminalRenderGridEnvelope.viewportReplacement(oldFrame)
    let latestEnvelope = try MobileTerminalRenderGridEnvelope.viewportReplacement(latestFrame)

    #expect(queue.enqueue(inFlight) == inFlight)
    #expect(queue.enqueue(
        TerminalOutputDelivery(renderGrid: oldEnvelope, replaceable: oldEnvelope.isReplaceableVisualUpdate)
    ) == nil)
    #expect(queue.enqueue(
        TerminalOutputDelivery(renderGrid: latestEnvelope, replaceable: latestEnvelope.isReplaceableVisualUpdate)
    ) == nil)

    #expect(queue.pendingCount == 1)
    let pendingOptional = queue.completeInFlight()
    let pending = try #require(pendingOptional)
    let pendingChunk = pending.chunk(streamToken: UUID())
    switch pendingChunk.payload {
    case .bytes:
        Issue.record("viewport replacement was downgraded to bytes")
    case .renderGrid(let envelope):
        #expect(envelope == latestEnvelope)
    }
    #expect(queue.completeInFlight() == nil)
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
    let nonreplaceableBytes = TerminalOutputDelivery(bytes: Data("barrier".utf8), replaceable: false)
    let laterViewport = TerminalOutputDelivery(bytes: Data("later viewport".utf8), replaceable: true)

    #expect(queue.enqueue(inFlight) == inFlight)
    #expect(queue.enqueue(viewport) == nil)
    #expect(queue.enqueue(nonreplaceableBytes) == nil)
    #expect(queue.enqueue(laterViewport) == nil)

    #expect(queue.pendingCount == 3)
    #expect(queue.completeInFlight() == viewport)
    #expect(queue.completeInFlight() == nonreplaceableBytes)
    #expect(queue.completeInFlight() == laterViewport)
    #expect(queue.completeInFlight() == nil)
}

@Test func terminalOutputQueueDrainsNonreplaceableBacklogInOrder() {
    var queue = TerminalOutputDeliveryQueue()
    let inFlight = TerminalOutputDelivery(bytes: Data("in-flight".utf8), replaceable: false)

    #expect(queue.enqueue(inFlight) == inFlight)
    for index in 0..<128 {
        let delivery = TerminalOutputDelivery(bytes: Data("barrier-\(index)".utf8), replaceable: false)
        #expect(queue.enqueue(delivery) == nil)
    }

    #expect(queue.pendingCount == 128)
    for index in 0..<128 {
        let expected = TerminalOutputDelivery(bytes: Data("barrier-\(index)".utf8), replaceable: false)
        #expect(queue.completeInFlight() == expected)
    }
    #expect(queue.completeInFlight() == nil)
    #expect(queue.isIdle)
}

@Test func terminalOutputQueueBoundsRenderGridBacklogAndSignalsReplayRepair() throws {
    var queue = TerminalOutputDeliveryQueue()
    let inFlight = TerminalOutputDelivery(bytes: Data("in-flight".utf8), replaceable: false)

    #expect(queue.enqueue(inFlight) == inFlight)
    for seq in 1...129 {
        let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "terminal",
            stateSeq: UInt64(seq),
            columns: 12,
            rows: 2,
            text: "delta-\(seq)",
            full: false,
            changedRows: [0]
        )
        let envelope = try MobileTerminalRenderGridEnvelope.viewportDelta(frame)
        #expect(queue.enqueue(TerminalOutputDelivery(renderGrid: envelope, replaceable: false)) == nil)
    }

    #expect(queue.pendingCount == 0)
    #expect(queue.consumeRenderGridOverflowStateSeq() == 129)
    #expect(queue.consumeRenderGridOverflowStateSeq() == nil)
    #expect(queue.completeInFlight() == nil)
    #expect(queue.isIdle)
}

private func testRenderGridEnvelope(
    surfaceID: String,
    seq: UInt64,
    text: String
) throws -> MobileTerminalRenderGridEnvelope {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: seq,
        columns: 20,
        rows: 2,
        text: text
    )
    return try MobileTerminalRenderGridEnvelope.snapshot(frame)
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
    #expect(!snapshot.isReplaceableVisualUpdate)
    #expect(!fullDelta.isReplaceableVisualUpdate)
    #expect(!partial.isReplaceableVisualUpdate)
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
    let replacement = try MobileTerminalRenderGridEnvelope.viewportReplacement(primaryWithScrollback)

    #expect(snapshot.ownsScrollback)
    #expect(snapshot.scrollbackRowsForLocalMirror == 8)
    #expect(snapshot.replayGrid?.columns == 12)
    #expect(snapshot.replayGrid?.rows == 2)
    #expect(!delta.ownsScrollback)
    #expect(delta.scrollbackRowsForLocalMirror == nil)
    #expect(delta.replayGrid == nil)
    #expect(!replacement.ownsScrollback)
    #expect(replacement.scrollbackRowsForLocalMirror == nil)
    #expect(replacement.replayGrid == nil)
}
