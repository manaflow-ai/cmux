import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
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

@MainActor
@Test func optimisticScrollPreservesAnUnappliedLiveViewportFrame() throws {
    var queue = TerminalOutputDeliveryQueue()
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 1,
        renderRevision: 7,
        columns: 12,
        rows: 2,
        text: "live\nviewport",
        full: false,
        changedRows: [0, 1]
    )
    let repaint = TerminalOutputDelivery(renderGrid: frame, replaceable: true)
    let receipt = TerminalSurfaceMutationReceipt()
    let scroll = TerminalOutputDelivery(
        localScroll: [MobileTerminalScrollRun(lines: -2, col: 1, row: 1)],
        receipt: receipt
    )

    #expect(queue.enqueue(repaint) == repaint)
    let result = queue.enqueueOptimisticScroll(scroll)

    #expect(result.immediate == nil)
    #expect(queue.currentInFlight == repaint)
    #expect(queue.completeInFlight() == scroll)
}

@MainActor
@Test func renderRevisionAdvancesOnlyAfterTheFrameIsApplied() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 5,
        renderRevision: 42,
        columns: 12,
        rows: 2,
        text: "applied\nrevision"
    )

    #expect(store.deliverAuthoritativeTerminalRenderGrid(frame, source: "event"))
    #expect(store.acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] == nil)

    let chunk = try #require(await iterator.next())
    #expect(store.terminalOutputWillProcess(
        surfaceID: surfaceID,
        streamToken: chunk.streamToken,
        deliveryID: chunk.deliveryID
    ))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: chunk.streamToken)

    #expect(store.acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] == 42)
}

@MainActor
@Test func renderDeltaRequiresItsProducerBaseButAcceptsAQueuedBase() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    let baseline = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 1,
        renderRevision: 9,
        columns: 12,
        rows: 2,
        text: "base\nframe"
    )
    var validDelta = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 2,
        renderRevision: 10,
        columns: 12,
        rows: 2,
        text: "next\nframe",
        full: false,
        changedRows: [0]
    )
    validDelta.baseRenderRevision = 9

    #expect(store.deliverAuthoritativeTerminalRenderGrid(baseline, source: "event"))
    #expect(store.deliverAuthoritativeTerminalRenderGrid(validDelta, source: "event"))

    let first = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: first.streamToken)
    let second = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: second.streamToken)

    var missingBase = validDelta
    missingBase.renderRevision = 12
    missingBase.baseRenderRevision = 11
    #expect(!store.deliverAuthoritativeTerminalRenderGrid(missingBase, source: "event"))
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
}

@MainActor
@Test func renderDeltaRejectsAnOlderProducerBaseAfterANewerFrameApplied() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    let baseline = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 1,
        renderRevision: 10,
        columns: 12,
        rows: 2,
        text: "newer\nbase"
    )

    #expect(store.deliverAuthoritativeTerminalRenderGrid(baseline, source: "event"))
    let delivered = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: delivered.streamToken)

    var skippedBase = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 2,
        renderRevision: 12,
        columns: 12,
        rows: 2,
        text: "unsafe\ndelta",
        full: false,
        changedRows: [0]
    )
    skippedBase.baseRenderRevision = 9

    #expect(!store.deliverAuthoritativeTerminalRenderGrid(skippedBase, source: "event"))
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
}

@MainActor
@Test func queuedNewerRenderFrameRejectsADelayedOlderFullFrame() throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    _ = store.terminalOutputStream(surfaceID: surfaceID)
    let newer = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 13,
        renderRevision: 13,
        columns: 12,
        rows: 2,
        text: "newer\nframe"
    )
    let delayedOlder = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 12,
        renderRevision: 12,
        columns: 12,
        rows: 2,
        text: "older\nframe"
    )

    #expect(store.deliverAuthoritativeTerminalRenderGrid(newer, source: "event"))
    #expect(!store.deliverAuthoritativeTerminalRenderGrid(delayedOlder, source: "event"))
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.projectedRenderRevision == 13)
}

@MainActor
@Test func exactQueuedRenderDeltaChainRemainsAccepted() throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    _ = store.terminalOutputStream(surfaceID: surfaceID)
    let baseline = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 10,
        renderRevision: 10,
        columns: 12,
        rows: 2,
        text: "base\nframe"
    )
    var firstDelta = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 11,
        renderRevision: 11,
        columns: 12,
        rows: 2,
        text: "first\nframe",
        full: false,
        changedRows: [0]
    )
    firstDelta.baseRenderRevision = 10
    var secondDelta = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 12,
        renderRevision: 12,
        columns: 12,
        rows: 2,
        text: "second\nframe",
        full: false,
        changedRows: [0]
    )
    secondDelta.baseRenderRevision = 11

    #expect(store.deliverAuthoritativeTerminalRenderGrid(baseline, source: "event"))
    #expect(store.deliverAuthoritativeTerminalRenderGrid(firstDelta, source: "event"))
    #expect(store.deliverAuthoritativeTerminalRenderGrid(secondDelta, source: "event"))
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.projectedRenderRevision == 12)
}

@MainActor
@Test func deferredFrameReappliesTheNewestOptimisticReversal() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 1,
        renderRevision: 4,
        columns: 12,
        rows: 2,
        text: "deferred\nframe"
    )
    let reversal = MobileTerminalScrollRun(lines: 7, col: 2, row: 1)
    store.deferTerminalRenderGridEvent(frame)

    store.flushDeferredTerminalRenderGridEvent(
        surfaceID: surfaceID,
        followingScrollRuns: [reversal]
    )

    let chunk = try #require(await iterator.next())
    guard case .output(let operation) = chunk.mutation else {
        Issue.record("expected deferred output")
        return
    }
    #expect(operation.followingScrollRuns == [reversal])
}

@MainActor
@Test func clickPreservesDeferredLiveFrameThroughGridlessReconciliation() async throws {
    let router = RoutingHostRouter()
    await router.setHoldFirstTerminalScroll(true)
    let store = try await makeRoutingConnectedStore(router: router)
    let surfaceID = RoutingHostRouter.terminalA
    let mounted = store.mountTerminalSurfaceOutput(surfaceID: surfaceID, cancelLocal: {})
    let token = mounted.scrollSessionToken
    var iterator = mounted.output.makeAsyncIterator()

    store.scrollTerminal(surfaceID: surfaceID, lines: -5, col: 2, row: 3)
    let local = try #require(await iterator.next())
    guard case .localScroll = local.mutation else {
        Issue.record("expected optimistic local scroll")
        return
    }
    #expect(store.terminalOutputWillProcess(
        surfaceID: surfaceID,
        streamToken: local.streamToken,
        deliveryID: local.deliveryID
    ))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: local.streamToken)
    await router.awaitFirstTerminalScrollReached()

    let live = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 10,
        renderRevision: 2,
        columns: 12,
        rows: 2,
        text: "live-row-a\nlive-row-b"
    )
    #expect(!store.deliverAuthoritativeTerminalRenderGrid(live, source: "event"))
    await store.clickTerminal(surfaceID: surfaceID, col: 4, row: 1)
    #expect(store.deferredTerminalRenderGridEventsBySurfaceID[surfaceID]?.frame == live)

    await router.releaseFirstTerminalScroll()
    let frameDelivered = try await pollUntil {
        store.terminalOutputQueuesBySurfaceID[surfaceID]?.currentInFlight?.bytes == live.vtPatchBytes()
    }
    #expect(frameDelivered)
    guard frameDelivered else { return }
    let frame = try #require(await iterator.next())
    #expect(frame.data == live.vtPatchBytes())
    #expect(store.terminalOutputWillProcess(
        surfaceID: surfaceID,
        streamToken: frame.streamToken,
        deliveryID: frame.deliveryID
    ))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: frame.streamToken)

    let barrier = try #require(await iterator.next())
    #expect(barrier.mutation == .barrier)
    #expect(store.terminalOutputWillProcess(
        surfaceID: surfaceID,
        streamToken: barrier.streamToken,
        deliveryID: barrier.deliveryID
    ))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: barrier.streamToken)
    let clickSent = try await pollUntil {
        await router.recordedTerminalInteractions().map(\.method).contains("mobile.terminal.mouse")
    }
    #expect(clickSent)
    store.unmountTerminalScrollSession(surfaceID: surfaceID, token: token)
}

@MainActor
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

@MainActor
@Test func historicalReplayOffsetIncludesTheReconstructedPrimaryActiveScreen() throws {
    let frame = try MobileTerminalRenderGridFrame.decodeJSONObject([
        "format": MobileTerminalRenderGridFrame.currentFormat,
        "surface_id": "terminal",
        "state_seq": 1,
        "columns": 12,
        "rows": 3,
        "full": true,
        "styles": [["id": 0]],
        "row_spans": [],
        "active_screen": "primary",
        "scrollforward_rows": 2,
        "scrollforward_spans": [],
        "primary_active_rows": 3,
        "primary_active_spans": [],
    ])

    let delivery = TerminalOutputDelivery(renderGrid: frame, replaceable: true)

    #expect(delivery.scrollbackOffsetFromBottomRows == 5)
}

@MainActor
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

@MainActor
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

@MainActor
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

@MainActor
@Test func terminalOutputUnmountRetainsEpochAndRetiresRenderRevision() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    _ = store.mountTerminalScrollSession(
        surfaceID: surfaceID,
        cancelLocal: {}
    )
    let interactionEpoch = try #require(store.terminalInteractionEpochsBySurfaceID[surfaceID])
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
        (store.terminalInteractionEpochsBySurfaceID[surfaceID] ?? 0) > interactionEpoch
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

    #expect(deferred.requiresReplay)
    #expect(deferred.frame == nil)
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
    #expect(store.acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] == 12)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: delivered.streamToken)
    #expect(store.acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] == deferredRevision)
    #expect(store.deferredTerminalRenderGridEventsBySurfaceID[surfaceID] == nil)
}

@MainActor
@Test func gridlessAcknowledgementAllowsOwedEqualRevisionReplay() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "live-terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    let deferred = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 1,
        renderRevision: 11,
        columns: 12,
        rows: 2,
        text: "older\ndeferred",
        full: false,
        changedRows: [0, 1]
    )
    store.deferTerminalRenderGridEvent(deferred)

    let completed = store.completeGridlessTerminalScrollReconciliation(
        surfaceID: surfaceID,
        renderRevision: 12
    )

    #expect(completed)
    #expect(store.acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] == 12)
    #expect(store.deferredTerminalRenderGridEventsBySurfaceID[surfaceID] == nil)
    let replay = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 2,
        renderRevision: 12,
        columns: 12,
        rows: 2,
        text: "recovered\nviewport",
        full: true
    )

    #expect(store.deliverAuthoritativeTerminalRenderGrid(replay, source: "replay"))
    let delivered = try #require(await iterator.next())
    #expect(delivered.data == replay.vtPatchBytes())
    #expect(store.equalRevisionTerminalRecoveryReplaysBySurfaceID[surfaceID] == 12)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: delivered.streamToken)
    #expect(store.equalRevisionTerminalRecoveryReplaysBySurfaceID[surfaceID] == nil)
}
