import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

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

@Test func terminalOutputQueueDoesNotReplaceRenderGridSnapshotWithPolicyOnlyDelivery() throws {
    var queue = TerminalOutputDeliveryQueue()
    let inFlight = TerminalOutputDelivery(bytes: Data("in-flight".utf8), replaceable: false)
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        columns: 12,
        rows: 2,
        text: "snapshot\ncontents",
        full: false,
        changedRows: [0, 1]
    )
    let renderGrid = TerminalOutputDelivery(renderGrid: frame, replaceable: true)
    let policyOnly = TerminalOutputDelivery(
        bytes: Data(),
        replaceable: true,
        replacementScope: .viewportPolicy,
        viewportPolicy: .natural
    )

    #expect(queue.enqueue(inFlight) == inFlight)
    #expect(queue.enqueue(renderGrid) == nil)
    #expect(queue.enqueue(policyOnly) == nil)

    #expect(queue.pendingCount == 2)
    let maybeDelivered = queue.completeInFlight()
    let delivered = try #require(maybeDelivered)
    let vt = try #require(String(data: delivered.bytes, encoding: .utf8))
    #expect(vt.contains("snapshot"))
    #expect(queue.completeInFlight() == policyOnly)
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

@Test func optimisticScrollDiscardsOnlyUnclaimedRenderGridDeliveries() throws {
    var queue = TerminalOutputDeliveryQueue()
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        columns: 12,
        rows: 2,
        text: "old\nviewport"
    )
    let yieldedGrid = TerminalOutputDelivery(renderGrid: frame, replaceable: true)
    let rawBytes = TerminalOutputDelivery(bytes: Data("raw".utf8), replaceable: false)
    let pendingGrid = TerminalOutputDelivery(renderGrid: frame, replaceable: true)

    #expect(queue.enqueue(yieldedGrid) == yieldedGrid)
    #expect(queue.enqueue(rawBytes) == nil)
    #expect(queue.enqueue(pendingGrid) == nil)

    #expect(queue.discardUnclaimedForOptimisticScroll() == rawBytes)
    let staleClaim = queue.claimInFlight(deliveryID: yieldedGrid.deliveryID)
    let rawClaim = queue.claimInFlight(deliveryID: rawBytes.deliveryID)
    #expect(!staleClaim)
    #expect(rawClaim)
    #expect(queue.pendingCount == 1)
    #expect(queue.completeInFlight() == nil)
}

@Test func optimisticScrollPreservesClaimedRenderGridAheadOfLocalWork() throws {
    var queue = TerminalOutputDeliveryQueue()
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        columns: 12,
        rows: 2,
        text: "claimed\nviewport"
    )
    let claimedGrid = TerminalOutputDelivery(renderGrid: frame, replaceable: true)
    let rawBytes = TerminalOutputDelivery(bytes: Data("raw".utf8), replaceable: false)
    let pendingGrid = TerminalOutputDelivery(renderGrid: frame, replaceable: true)

    #expect(queue.enqueue(claimedGrid) == claimedGrid)
    let claimed = queue.claimInFlight(deliveryID: claimedGrid.deliveryID)
    #expect(claimed)
    #expect(queue.enqueue(rawBytes) == nil)
    #expect(queue.enqueue(pendingGrid) == nil)

    #expect(queue.discardUnclaimedForOptimisticScroll() == nil)
    #expect(queue.currentInFlight == claimedGrid)
    #expect(queue.completeInFlight() == rawBytes)
    #expect(queue.completeInFlight() == nil)
}

@Test func optimisticScrollPreservesUnclaimedIncrementalRenderGrid() throws {
    var queue = TerminalOutputDeliveryQueue()
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        columns: 12,
        rows: 2,
        text: "changed\nunchanged",
        full: false,
        changedRows: [0]
    )
    let incrementalGrid = TerminalOutputDelivery(renderGrid: frame, replaceable: false)
    let rawBytes = TerminalOutputDelivery(bytes: Data("raw".utf8), replaceable: false)
    let replaceableGrid = TerminalOutputDelivery(
        renderGrid: try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "terminal",
            stateSeq: 2,
            columns: 12,
            rows: 2,
            text: "new\nviewport",
            full: false,
            changedRows: [0, 1]
        ),
        replaceable: true
    )

    #expect(queue.enqueue(incrementalGrid) == incrementalGrid)
    #expect(queue.enqueue(rawBytes) == nil)
    #expect(queue.enqueue(replaceableGrid) == nil)

    #expect(queue.discardUnclaimedForOptimisticScroll() == nil)
    #expect(queue.currentInFlight == incrementalGrid)
    #expect(queue.completeInFlight() == rawBytes)
    #expect(queue.completeInFlight() == nil)
}

@Test func optimisticScrollDiscardsUnclaimedIncrementalReconciliation() throws {
    var queue = TerminalOutputDeliveryQueue()
    let reconciliation = TerminalScrollReconciliation(interactionEpoch: 1, clientRevision: 1)
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        columns: 12,
        rows: 2,
        text: "old\nreconcile",
        full: false,
        changedRows: [0]
    )
    let stale = TerminalOutputDelivery(
        renderGrid: frame,
        replaceable: false,
        scrollReconciliation: reconciliation
    )
    let rawBytes = TerminalOutputDelivery(bytes: Data("raw".utf8), replaceable: false)

    #expect(queue.enqueue(stale) == stale)
    #expect(queue.enqueue(rawBytes) == nil)
    #expect(queue.discardUnclaimedForOptimisticScroll() == rawBytes)
    let staleClaim = queue.claimInFlight(deliveryID: stale.deliveryID)
    let rawClaim = queue.claimInFlight(deliveryID: rawBytes.deliveryID)
    #expect(!staleClaim)
    #expect(rawClaim)
}

@Test func optimisticScrollInvalidationIsLazyAndPreservesOrderedBarriers() throws {
    var queue = TerminalOutputDeliveryQueue()
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        columns: 12,
        rows: 2,
        text: "old\nviewport"
    )
    let claimedGrid = TerminalOutputDelivery(renderGrid: frame, replaceable: true)
    #expect(queue.enqueue(claimedGrid) == claimedGrid)
    let claimed = queue.claimInFlight(deliveryID: claimedGrid.deliveryID)
    #expect(claimed)

    let rawDeliveries = (0..<64).map {
        TerminalOutputDelivery(bytes: Data("raw-\($0)".utf8), replaceable: false)
    }
    for raw in rawDeliveries {
        #expect(queue.enqueue(TerminalOutputDelivery(renderGrid: frame, replaceable: true)) == nil)
        #expect(queue.enqueue(raw) == nil)
    }
    let policy = TerminalOutputDelivery(
        bytes: Data(),
        replaceable: true,
        replacementScope: .viewportPolicy,
        viewportPolicy: .natural
    )
    let incremental = TerminalOutputDelivery(renderGrid: frame, replaceable: false)
    #expect(queue.enqueue(policy) == nil)
    #expect(queue.enqueue(incremental) == nil)

    for _ in 0..<100 {
        #expect(queue.discardUnclaimedForOptimisticScroll() == nil)
    }
    #expect(queue.optimisticInvalidationGeneration == 100)
    #expect(queue.pendingTraversalCount == 0)

    for raw in rawDeliveries {
        #expect(queue.completeInFlight() == raw)
    }
    #expect(queue.completeInFlight() == policy)
    #expect(queue.completeInFlight() == incremental)
    #expect(queue.completeInFlight() == nil)
    #expect(queue.pendingTraversalCount == 130)
}

@MainActor
@Test func terminalOutputUnmountRetiresScrollRevisionState() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    _ = store.mountTerminalScrollSession(
        surfaceID: surfaceID,
        applyLocal: { _ in true },
        cancelLocal: {}
    )
    store.acceptTerminalRenderRevision(42, surfaceID: surfaceID)
    let consumer = Task { @MainActor in
        for await _ in store.terminalOutputStream(surfaceID: surfaceID) {}
    }
    let registered = try await pollUntil {
        store.terminalOutputStreamTokensBySurfaceID[surfaceID] != nil
    }
    #expect(registered)

    consumer.cancel()
    await consumer.value
    let retired = try await pollUntil {
        store.terminalInteractionEpochsBySurfaceID[surfaceID] == nil
            && store.acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] == nil
    }
    #expect(retired)
}

@Test func deferredIncrementalRenderGridsRequireReplayWithoutGrowingAQueue() throws {
    let first = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        renderRevision: 1,
        columns: 12,
        rows: 2,
        text: "first\nrow",
        full: false,
        changedRows: [0]
    )
    let second = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 2,
        renderRevision: 2,
        columns: 12,
        rows: 2,
        text: "second\nrow",
        full: false,
        changedRows: [1]
    )
    var deferred = DeferredTerminalRenderGridEvent(frame: first)

    deferred.append(second)

    #expect(deferred.requiresReplay)
    #expect(deferred.frame == nil)
}

@Test func deferredFullViewportPatchSupersedesEarlierDelta() throws {
    let first = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        renderRevision: 1,
        columns: 12,
        rows: 2,
        text: "first\nrow",
        full: false,
        changedRows: [0]
    )
    let replacement = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 2,
        renderRevision: 2,
        columns: 12,
        rows: 2,
        text: "replacement\nviewport",
        full: false,
        changedRows: [0, 1]
    )
    var deferred = DeferredTerminalRenderGridEvent(frame: first)

    deferred.append(replacement)

    #expect(!deferred.requiresReplay)
    #expect(deferred.frame == replacement)
}

@MainActor
@Test(arguments: [UInt64(12), UInt64(13)])
func gridlessAcknowledgementDeliversSameOrNewerDeferredFrameBeforeAdvancingFloor(
    deferredRevision: UInt64
) async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 1,
        renderRevision: deferredRevision,
        columns: 12,
        rows: 2,
        text: "ack\ndeferred",
        full: false,
        changedRows: [0, 1]
    )
    store.deferTerminalRenderGridEvent(frame)

    let completed = store.completeGridlessTerminalScrollReconciliation(
        surfaceID: surfaceID,
        renderRevision: 12
    )

    #expect(completed)
    let delivered = try #require(await iterator.next())
    #expect(delivered.data == frame.vtPatchBytes())
    #expect(store.acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] == deferredRevision)
    #expect(store.deferredTerminalRenderGridEventsBySurfaceID[surfaceID] == nil)
}

@MainActor
@Test func gridlessAcknowledgementReplaysInsteadOfPaintingOlderDeferredFrame() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 1,
        renderRevision: 11,
        columns: 12,
        rows: 2,
        text: "older\ndeferred",
        full: false,
        changedRows: [0, 1]
    )
    store.deferTerminalRenderGridEvent(frame)
    let replayCount = await router.count(of: "mobile.terminal.replay")

    let completed = store.completeGridlessTerminalScrollReconciliation(
        surfaceID: surfaceID,
        renderRevision: 12
    )

    #expect(completed)
    let replayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") == replayCount + 1
    }
    #expect(replayRequested)
    #expect(store.acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] == 12)
    #expect(store.deferredTerminalRenderGridEventsBySurfaceID[surfaceID] == nil)
}
