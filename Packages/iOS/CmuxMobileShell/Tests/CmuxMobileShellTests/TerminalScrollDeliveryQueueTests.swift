import Foundation
import Testing
@testable import CmuxMobileShell

@Test func terminalScrollQueueDeliversFirstDeltaImmediately() {
    var queue = TerminalScrollDeliveryQueue()
    let first = TerminalScrollDelivery(surfaceID: "surface", lines: 1.25, col: 4, row: 8)

    #expect(queue.enqueue(first) == first)
    #expect(queue.isIdle == false)
}

@Test func terminalScrollQueueIgnoresCompletionWhenNothingIsInFlight() {
    var queue = TerminalScrollDeliveryQueue()

    #expect(queue.completeInFlight() == nil)
    #expect(queue.isIdle)
}

@Test func terminalScrollQueueCoalescesPendingDeltasBehindInFlightRequest() throws {
    var queue = TerminalScrollDeliveryQueue()
    let inFlight = TerminalScrollDelivery(surfaceID: "surface", lines: 1, col: 1, row: 1)
    let firstPending = TerminalScrollDelivery(surfaceID: "surface", lines: 2.5, col: 4, row: 8)
    let latestPending = TerminalScrollDelivery(surfaceID: "surface", lines: -0.75, col: 7, row: 9)

    #expect(queue.enqueue(inFlight) == inFlight)
    #expect(queue.enqueue(firstPending) == nil)
    #expect(queue.enqueue(latestPending) == nil)

    let maybeCoalesced = queue.completeInFlight()
    let coalesced = try #require(maybeCoalesced)
    #expect(coalesced.surfaceID == "surface")
    #expect(coalesced.lines == 1.75)
    #expect(coalesced.col == 7)
    #expect(coalesced.row == 9)
    #expect(queue.completeInFlight() == nil)
    #expect(queue.isIdle)
}

@Test func terminalScrollQueueCoalescesLargestScrollbackPrefetchWindow() throws {
    var queue = TerminalScrollDeliveryQueue()
    let inFlight = TerminalScrollDelivery(surfaceID: "surface", lines: 1, col: 1, row: 1)
    let firstPending = TerminalScrollDelivery(
        surfaceID: "surface",
        lines: 2,
        col: 2,
        row: 2,
        maxScrollbackRows: 240
    )
    let latestPending = TerminalScrollDelivery(
        surfaceID: "surface",
        lines: 3,
        col: 3,
        row: 3,
        maxScrollbackRows: 600
    )

    #expect(queue.enqueue(inFlight) == inFlight)
    #expect(queue.enqueue(firstPending) == nil)
    #expect(queue.enqueue(latestPending) == nil)

    let maybeCoalesced = queue.completeInFlight()
    let coalesced = try #require(maybeCoalesced)
    #expect(coalesced.lines == 5)
    #expect(coalesced.col == 3)
    #expect(coalesced.row == 3)
    #expect(coalesced.maxScrollbackRows == 600)
}

@Test func terminalScrollbackPrefetchStatePrimesThenRefreshesByDistance() {
    var state = TerminalScrollbackPrefetchState(windowRows: 600, refreshDistanceRows: 10)

    #expect(state.rowsToPrefetch(forScrollLines: 0) == nil)
    #expect(state.rowsToPrefetch(forScrollLines: 1) == 600)
    #expect(state.rowsToPrefetch(forScrollLines: 4) == nil)
    #expect(state.rowsToPrefetch(forScrollLines: -5.5) == nil)
    #expect(state.rowsToPrefetch(forScrollLines: 0.5) == 600)
}

@Test func terminalScrollQueueResetDropsPendingWork() {
    var queue = TerminalScrollDeliveryQueue()
    let inFlight = TerminalScrollDelivery(surfaceID: "surface", lines: 1, col: 1, row: 1)
    let pending = TerminalScrollDelivery(surfaceID: "surface", lines: 2, col: 2, row: 2)

    #expect(queue.enqueue(inFlight) == inFlight)
    #expect(queue.enqueue(pending) == nil)
    queue.reset()

    #expect(queue.isIdle)
    #expect(queue.completeInFlight() == nil)
}

@MainActor
@Test func staleScrollCompletionDoesNotAdvanceReplacementQueue() throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "surface"
    let staleToken = UUID()
    let currentToken = UUID()
    let inFlight = TerminalScrollDelivery(surfaceID: surfaceID, lines: 1, col: 1, row: 1)
    let pending = TerminalScrollDelivery(surfaceID: surfaceID, lines: 2, col: 2, row: 2)

    var replacementQueue = TerminalScrollDeliveryQueue()
    #expect(replacementQueue.enqueue(inFlight) == inFlight)
    #expect(replacementQueue.enqueue(pending) == nil)
    store.terminalScrollQueuesBySurfaceID[surfaceID] = replacementQueue
    store.terminalScrollQueueTokensBySurfaceID[surfaceID] = currentToken

    store.terminalScrollDidComplete(surfaceID: surfaceID, queueToken: staleToken)

    var queueAfterStaleCompletion = try #require(store.terminalScrollQueuesBySurfaceID[surfaceID])
    #expect(queueAfterStaleCompletion.completeInFlight() == pending)
}
