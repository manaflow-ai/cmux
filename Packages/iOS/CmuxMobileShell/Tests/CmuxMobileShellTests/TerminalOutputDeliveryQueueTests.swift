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
    #expect(String(data: secondChunk.data, encoding: .utf8) == "new-second")
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
    #expect(String(data: replayChunk.data, encoding: .utf8) == "authoritative-replay")
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
    #expect(String(data: afterReplayAck.data, encoding: .utf8) == "after-replay-ack")
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
    #expect(String(data: afterAbort.data, encoding: .utf8) == "after-aborted-replay")
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
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let coldReplaySettled = await waitForReplayBarrierFailureToSettle {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(coldReplaySettled, "cold mount replay must settle before starting the held replay")
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    store.deliverTerminalBytes(Data("stalled-first".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    store.deliverTerminalBytes(Data("stale-second".utf8), surfaceID: surfaceID)

    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: stalledChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)

    let replayChunk = try #require(await iterator.next())
    #expect(String(data: replayChunk.data, encoding: .utf8) == "first-replay")

    let acceptedDuringBarrier = store.deliverTerminalBytes(
        Data("live-during-barrier".utf8),
        surfaceID: surfaceID
    )
    #expect(acceptedDuringBarrier == false)
    #expect(store.terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID))

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 2)

    let followUpChunk = try #require(await iterator.next())
    #expect(String(data: followUpChunk.data, encoding: .utf8) == "follow-up-replay")
    #expect(!store.terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID))

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: followUpChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.deliverTerminalBytes(Data("after-follow-up".utf8), surfaceID: surfaceID)
    let afterFollowUp = try #require(await iterator.next())
    #expect(String(data: afterFollowUp.data, encoding: .utf8) == "after-follow-up")
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
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    await router.failNextReplay()
    _ = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    let firstDropAccepted = store.deliverTerminalBytes(
        Data("live-during-failed-replay".utf8),
        surfaceID: surfaceID
    )
    #expect(firstDropAccepted == false)

    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)

    let retryRequested = await waitForReplayRequestCount(
        router,
        atLeast: replayCountAfterMount + 2
    )
    #expect(retryRequested, "failed replay with dropped output must request a replacement replay")
    #expect(store.terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID))

    let retryReplayChunk = try #require(await iterator.next())
    #expect(String(data: retryReplayChunk.data, encoding: .utf8) == "retry-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: retryReplayChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
    #expect(!store.terminalReplayBarrierDroppedOutputSurfaceIDs.contains(surfaceID))
}

@MainActor
@Test func terminalReplayBarrierRetriesAfterReplayFailureWithoutDroppedOutput() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "retry-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    await router.failNextReplay()
    store.deliverTerminalBytes(Data("stalled-first".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: stalledChunk.streamToken)

    let retryRequested = await waitForReplayRequestCount(
        router,
        atLeast: replayCountAfterMount + 2
    )
    #expect(retryRequested, "failed reset replay must retry even without a later live-output drop")
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil)

    if retryRequested {
        let retryReplayChunk = try #require(await iterator.next())
        #expect(String(data: retryReplayChunk.data, encoding: .utf8) == "retry-replay")
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: retryReplayChunk.streamToken)
        #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
    }
}

@MainActor
@Test func terminalReplayBarrierReplaysOnReplacementClientAfterStaleResponse() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    await router.holdNextReplayResponses()

    store.deliverTerminalBytes(Data("stalled-first".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: stalledChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)

    let replacementRouter = LivenessHostRouter()
    let replacementBox = TransportBox()
    await replacementRouter.enqueueReplayTexts(["replacement-replay"])
    try installFreshLivenessRemoteClient(
        on: store,
        router: replacementRouter,
        box: replacementBox,
        clock: clock
    )
    await router.enqueueReplayTexts(["stale-replay"])
    await router.releaseAllHeld()

    let replacementReplayRequested = await waitForReplayRequestCount(
        replacementRouter,
        atLeast: 1
    )
    #expect(replacementReplayRequested, "stale replay responses must resync on the replacement client")

    if replacementReplayRequested {
        let replacementReplayChunk = try #require(await iterator.next())
        #expect(String(data: replacementReplayChunk.data, encoding: .utf8) == "replacement-replay")
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replacementReplayChunk.streamToken)
        #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
    }
}

@MainActor
@Test func terminalReplayBarrierReplaysOnReplacementClientAfterStaleFailure() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    await router.holdNextReplayResponses()

    store.deliverTerminalBytes(Data("stalled-first".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: stalledChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)

    let replacementRouter = LivenessHostRouter()
    let replacementBox = TransportBox()
    await replacementRouter.enqueueReplayTexts(["replacement-replay"])
    try installFreshLivenessRemoteClient(
        on: store,
        router: replacementRouter,
        box: replacementBox,
        clock: clock
    )
    await router.failNextReplay()
    await router.releaseAllHeld()

    let replacementReplayRequested = await waitForReplayRequestCount(
        replacementRouter,
        atLeast: 1
    )
    #expect(replacementReplayRequested, "stale replay failures must resync on the replacement client")

    if replacementReplayRequested {
        let replacementReplayChunk = try #require(await iterator.next())
        #expect(String(data: replacementReplayChunk.data, encoding: .utf8) == "replacement-replay")
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replacementReplayChunk.streamToken)
        #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
    }
}

@MainActor
@Test func terminalReplayBarrierStaysActiveAfterRetryExhaustionWithoutDroppedOutput() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    await router.failNextReplay(count: 3)
    store.deliverTerminalBytes(Data("stalled-first".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: stalledChunk.streamToken)

    let exhaustedRetries = await waitForReplayRequestCount(
        router,
        atLeast: replayCountAfterMount + 3
    )
    #expect(exhaustedRetries, "reset replay should exhaust the initial request plus two retries")

    let failureSettled = await waitForReplayBarrierFailureToSettle {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(failureSettled)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil)

    let replayCountAfterExhaustion = await router.count(of: "mobile.terminal.replay")
    let acceptedAfterExhaustion = store.deliverTerminalBytes(
        Data("live-after-exhausted-replay".utf8),
        surfaceID: surfaceID
    )
    #expect(acceptedAfterExhaustion == false)
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    let replayRestartedAfterExhaustion = await waitForReplayRequestCount(
        router,
        atLeast: replayCountAfterExhaustion + 1
    )
    #expect(!replayRestartedAfterExhaustion, "dropped live output must not bypass the replay retry cap")
}

@MainActor
@Test func terminalReplayInFlightClearsWhenOutputStreamUnmountsBeforeResponse() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.holdNextReplayResponses()
    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    #expect(store.terminalReplaySurfaceIDsInFlight.contains(surfaceID))

    collector.unmount()
    let unregistered = await waitForReplayBarrierFailureToSettle {
        store.terminalByteContinuationsBySurfaceID[surfaceID] == nil
    }
    #expect(unregistered)
    #expect(!store.terminalReplaySurfaceIDsInFlight.contains(surfaceID))

    let replayCountAfterUnmount = await router.count(of: "mobile.terminal.replay")
    await router.enqueueReplayTexts(["remount-replay"])
    let remountCollector = OutputCollector()
    remountCollector.mount(store: store, surfaceID: surfaceID)

    await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterUnmount + 1
    )
    let replayDelivered = try await pollUntil {
        remountCollector.lines.contains("remount-replay")
    }
    #expect(replayDelivered)

    remountCollector.unmount()
    await router.releaseAllHeld()
}

@MainActor
@Test func staleReplayResponseAfterRemountDoesNotDeliverIntoCurrentStream() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.holdNextReplayResponses()
    let oldCollector = OutputCollector()
    oldCollector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    oldCollector.unmount()

    let unregistered = await waitForReplayBarrierFailureToSettle {
        store.terminalByteContinuationsBySurfaceID[surfaceID] == nil
    }
    #expect(unregistered)
    let replayCountAfterUnmount = await router.count(of: "mobile.terminal.replay")

    await router.enqueueReplayTexts(["fresh-replay", "stale-replay"])
    let currentCollector = OutputCollector()
    currentCollector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterUnmount + 1
    )

    let freshDelivered = try await pollUntil {
        currentCollector.lines.contains("fresh-replay")
    }
    #expect(freshDelivered)

    await router.releaseAllHeld()
    let staleDelivered = try await pollUntil(attempts: 50) {
        currentCollector.lines.contains("stale-replay")
    }
    #expect(!staleDelivered, "superseded replay responses must not deliver stale bytes")

    currentCollector.unmount()
}

@MainActor
@Test func genericReplayRequestReusesPreservedBarrierAfterRetryExhaustion() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    await router.failNextReplay(count: 3)
    store.deliverTerminalBytes(Data("stalled-first".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: stalledChunk.streamToken)

    let exhaustedRetries = await waitForReplayRequestCount(
        router,
        atLeast: replayCountAfterMount + 3
    )
    #expect(exhaustedRetries, "reset replay should exhaust the initial request plus two retries")

    let failureSettled = await waitForReplayBarrierFailureToSettle {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(failureSettled)
    let preservedBarrierToken = try #require(store.terminalReplayBarrierTokensBySurfaceID[surfaceID])

    let replayCountAfterExhaustion = await router.count(of: "mobile.terminal.replay")
    await router.enqueueReplayTexts(["resync-replay"])
    store.requestTerminalReplay(surfaceID: surfaceID)

    let genericReplayRequested = await waitForReplayRequestCount(
        router,
        atLeast: replayCountAfterExhaustion + 1
    )
    #expect(genericReplayRequested, "generic resync must not be blocked by a preserved barrier")

    if genericReplayRequested {
        let replayChunk = try #require(await iterator.next())
        #expect(String(data: replayChunk.data, encoding: .utf8) == "resync-replay")
        #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == preservedBarrierToken)
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
        #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
    }
}

@MainActor
@Test func terminalReplayBarrierRetriesWhenReplayAckChunkResets() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "first-replay", "retry-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    store.deliverTerminalBytes(Data("stalled-first".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    store.deliverTerminalBytes(Data("stale-second".utf8), surfaceID: surfaceID)

    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: stalledChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)

    let replayChunk = try #require(await iterator.next())
    #expect(String(data: replayChunk.data, encoding: .utf8) == "first-replay")
    let firstBarrierToken = try #require(store.terminalReplayBarrierTokensBySurfaceID[surfaceID])

    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 2)

    let retryReplayChunk = try #require(await iterator.next())
    #expect(String(data: retryReplayChunk.data, encoding: .utf8) == "retry-replay")
    let retryBarrierToken = try #require(store.terminalReplayBarrierTokensBySurfaceID[surfaceID])
    #expect(retryBarrierToken != firstBarrierToken)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: retryReplayChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
}

@MainActor
@Test func terminalReplayBarrierRequestsFollowUpForDropAfterCoveredRetryResponse() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "retry-replay", "follow-up-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    await router.failNextReplay()
    let replayBarrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    let firstDropAccepted = store.deliverTerminalBytes(
        Data("live-during-failed-replay".utf8),
        surfaceID: surfaceID
    )
    #expect(firstDropAccepted == false)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)

    let failureSettled = await waitForReplayBarrierFailureToSettle {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == replayBarrierToken
    }
    #expect(failureSettled)

    let retryDropAccepted = store.deliverTerminalBytes(
        Data("live-before-retry-request".utf8),
        surfaceID: surfaceID
    )
    #expect(retryDropAccepted == false)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 2)

    let retryReplayChunk = try #require(await iterator.next())
    #expect(String(data: retryReplayChunk.data, encoding: .utf8) == "retry-replay")

    let postResponseDropAccepted = store.deliverTerminalBytes(
        Data("live-after-retry-response-before-ack".utf8),
        surfaceID: surfaceID
    )
    #expect(postResponseDropAccepted == false)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: retryReplayChunk.streamToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 3)

    let followUpChunk = try #require(await iterator.next())
    #expect(String(data: followUpChunk.data, encoding: .utf8) == "follow-up-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: followUpChunk.streamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
}

@MainActor
@Test func terminalReplayBarrierRetriesEmptyReplayAfterDroppedOutput() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    await router.enqueueEmptyReplayResponses()
    await router.enqueueReplayTexts(["follow-up-replay"])
    let replayBarrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    let droppedOutputAccepted = store.deliverTerminalBytes(
        Data("live-during-empty-replay".utf8),
        surfaceID: surfaceID
    )
    #expect(droppedOutputAccepted == false)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == replayBarrierToken)

    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)
    let followUpReplayRequested = await waitForReplayRequestCount(
        router,
        atLeast: replayCountAfterMount + 2
    )
    #expect(followUpReplayRequested, "empty replay with dropped output must immediately request a replacement replay")

    if followUpReplayRequested {
        let followUpChunk = try #require(await iterator.next())
        #expect(String(data: followUpChunk.data, encoding: .utf8) == "follow-up-replay")
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: followUpChunk.streamToken)
        #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
    }
}

@MainActor
private func waitForReplayBarrierFailureToSettle(
    _ condition: @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<300 {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

private func waitForReplayRequestCount(
    _ router: LivenessHostRouter,
    atLeast expectedCount: Int
) async -> Bool {
    for _ in 0..<300 {
        if await router.count(of: "mobile.terminal.replay") >= expectedCount {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await router.count(of: "mobile.terminal.replay") >= expectedCount
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
