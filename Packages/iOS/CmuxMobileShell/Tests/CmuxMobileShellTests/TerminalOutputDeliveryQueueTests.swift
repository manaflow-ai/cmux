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

@MainActor
@Test func terminalReplayBarrierDropsStalledBacklogAndInvalidatesOldAcks() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"

    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    store.deliverTerminalBytes(Data("stalled-first".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    store.deliverTerminalBytes(Data("stale-second".utf8), surfaceID: surfaceID)

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount == 1)

    let replayBarrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == replayBarrierToken)

    let liveBeforeReplayAccepted = store.deliverTerminalBytes(
        Data("live-before-replay".utf8),
        surfaceID: surfaceID
    )
    #expect(liveBeforeReplayAccepted == false)
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: stalledChunk.streamToken)

    store.deliverTerminalBytes(
        Data("authoritative-replay".utf8),
        surfaceID: surfaceID,
        bypassReplayBarrier: true
    )
    let replayChunk = try #require(await iterator.next())
    #expect(String(decoding: replayChunk.data, as: UTF8.self) == "authoritative-replay")
    #expect(replayChunk.streamToken != stalledChunk.streamToken)

    let liveBeforeReplayAckAccepted = store.deliverTerminalBytes(
        Data("live-before-replay-ack".utf8),
        surfaceID: surfaceID
    )
    #expect(liveBeforeReplayAckAccepted == false)
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount == 0)

    let afterStaleAckAccepted = store.deliverTerminalBytes(
        Data("after-stale-ack".utf8),
        surfaceID: surfaceID
    )
    #expect(afterStaleAckAccepted == false)
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount == 0)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.deliverTerminalBytes(Data("after-replay-ack".utf8), surfaceID: surfaceID)

    let afterReplayAck = try #require(await iterator.next())
    #expect(String(decoding: afterReplayAck.data, as: UTF8.self) == "after-replay-ack")
}

@MainActor
@Test func terminalOutputResetClearsBarrierWhenReplayCannotStart() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"

    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    store.deliverTerminalBytes(Data("stalled-first".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    store.deliverTerminalBytes(Data("stale-second".utf8), surfaceID: surfaceID)

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount == 1)

    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: stalledChunk.streamToken)

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: stalledChunk.streamToken)

    let accepted = store.deliverTerminalBytes(Data("after-aborted-replay".utf8), surfaceID: surfaceID)
    #expect(accepted == true)

    let afterAbort = try #require(await iterator.next())
    #expect(String(decoding: afterAbort.data, as: UTF8.self) == "after-aborted-replay")
}

@MainActor
@Test func terminalReplayBarrierRequestsFollowUpWhenLiveOutputDropsBeforeAck() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "first-replay", "follow-up-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(decoding: coldReplayChunk.data, as: UTF8.self) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    store.deliverTerminalBytes(Data("stalled-first".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    store.deliverTerminalBytes(Data("stale-second".utf8), surfaceID: surfaceID)

    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: stalledChunk.streamToken)
    let sawResetReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayCountAfterMount + 1
    }
    #expect(sawResetReplay, "reset must request an authoritative replay")

    let replayChunk = try #require(await iterator.next())
    #expect(String(decoding: replayChunk.data, as: UTF8.self) == "first-replay")

    let acceptedDuringBarrier = store.deliverTerminalBytes(
        Data("live-during-barrier".utf8),
        surfaceID: surfaceID
    )
    #expect(acceptedDuringBarrier == false)
    #expect(store.terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID))

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
    let sawFollowUpReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayCountAfterMount + 2
    }
    #expect(sawFollowUpReplay, "live output dropped during a replay barrier must trigger a follow-up replay")

    let followUpChunk = try #require(await iterator.next())
    #expect(String(decoding: followUpChunk.data, as: UTF8.self) == "follow-up-replay")
    #expect(!store.terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID))

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: followUpChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.deliverTerminalBytes(Data("after-follow-up".utf8), surfaceID: surfaceID)
    let afterFollowUp = try #require(await iterator.next())
    #expect(String(decoding: afterFollowUp.data, as: UTF8.self) == "after-follow-up")
}

@MainActor
@Test func terminalReplayBarrierRetriesAfterReplayFailureWithDroppedOutput() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "retry-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    let sawMountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawMountReplay, "mounting a sink must arm the cold-attach replay")
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(decoding: coldReplayChunk.data, as: UTF8.self) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    await router.failNextReplay()
    let replayBarrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    let firstDropAccepted = store.deliverTerminalBytes(
        Data("live-during-failed-replay".utf8),
        surfaceID: surfaceID
    )
    #expect(firstDropAccepted == false)

    let sawFailedReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayCountAfterMount + 1
    }
    #expect(sawFailedReplay, "first dropped live output should request a replay")

    let failureSettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == replayBarrierToken
    }
    #expect(failureSettled, "failed replay with dropped output must keep the barrier active")
    #expect(store.terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID))

    let retryDropAccepted = store.deliverTerminalBytes(
        Data("live-after-failed-replay".utf8),
        surfaceID: surfaceID
    )
    #expect(retryDropAccepted == false)
    let sawRetryReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= replayCountAfterMount + 2
    }
    #expect(sawRetryReplay, "next dropped live output should retry the preserved barrier replay")

    let retryReplayChunk = try #require(await iterator.next())
    #expect(String(decoding: retryReplayChunk.data, as: UTF8.self) == "retry-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: retryReplayChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
    #expect(!store.terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID))
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
