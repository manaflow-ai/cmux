#if canImport(UIKit)
import Testing

@testable import CmuxMobileTerminal

@MainActor
@Suite("Local scrollback scroll queue")
struct LocalScrollbackScrollQueueTests {
    @Test("retains one in-flight request and merges newer movement")
    func mergesPendingMovement() throws {
        var queue = LocalScrollbackScrollQueue()
        let first = LocalScrollbackScrollRequest(lines: 12, col: 1, row: 2)

        #expect(queue.enqueue(first) == first)
        #expect(queue.enqueue(.init(lines: 8, col: 3, row: 4)) == nil)
        #expect(queue.enqueue(.init(lines: -3, col: 5, row: 6)) == nil)

        let completedValue = queue.completeInFlight()
        let completed = try #require(completedValue)
        let next = try #require(completed.next)
        #expect(completed.shouldForward)
        #expect(next == LocalScrollbackScrollRequest(lines: 5, col: 5, row: 6))
        let finalValue = queue.completeInFlight()
        let final = try #require(finalValue)
        #expect(final.next == nil)
        #expect(final.shouldForward)
        #expect(queue.isIdle)
    }

    @Test("drops pending movement that cancels before it is applied")
    func dropsCancelledPendingMovement() {
        var queue = LocalScrollbackScrollQueue()

        _ = queue.enqueue(.init(lines: 9, col: 1, row: 2))
        _ = queue.enqueue(.init(lines: 4, col: 3, row: 4))
        _ = queue.enqueue(.init(lines: -4, col: 5, row: 6))

        let completed = queue.completeInFlight()
        #expect(completed?.next == nil)
        #expect(completed?.shouldForward == true)
        #expect(queue.isIdle)
    }

    @Test("recovery carries net outstanding movement onto the new surface")
    func takesOutstandingMovementForRecovery() throws {
        var queue = LocalScrollbackScrollQueue()

        _ = queue.enqueue(.init(lines: 11, col: 1, row: 2))
        _ = queue.enqueue(.init(lines: -7, col: 3, row: 4))
        _ = queue.enqueue(.init(lines: 2, col: 5, row: 6))

        let recovered = queue.takeOutstanding()
        let outstanding = try #require(recovered)
        #expect(outstanding == LocalScrollbackScrollRequest(lines: 6, col: 5, row: 6))
        #expect(queue.isIdle)
    }

    @Test("typed input suppresses stale forwarding but preserves newer movement")
    func suppressesStaleForwarding() throws {
        var queue = LocalScrollbackScrollQueue()
        let fresh = LocalScrollbackScrollRequest(lines: 6, col: 5, row: 6)

        _ = queue.enqueue(.init(lines: 10, col: 1, row: 2))
        _ = queue.enqueue(.init(lines: -3, col: 3, row: 4))
        queue.suppressInFlightForwardingAndDiscardPending()
        _ = queue.enqueue(fresh)

        let staleValue = queue.completeInFlight()
        let staleCompletion = try #require(staleValue)
        #expect(!staleCompletion.shouldForward)
        #expect(staleCompletion.next == fresh)
        let freshValue = queue.completeInFlight()
        let freshCompletion = try #require(freshValue)
        #expect(freshCompletion.shouldForward)
        #expect(freshCompletion.next == nil)
        #expect(queue.isIdle)
    }
}
#endif
