#if canImport(UIKit)
import Testing

@testable import CmuxMobileTerminal

@Suite("Local scrollback scroll queue")
struct LocalScrollbackScrollQueueTests {
    @Test("retains one in-flight request and merges newer movement")
    func mergesPendingMovement() throws {
        var queue = LocalScrollbackScrollQueue()
        let first = LocalScrollbackScrollRequest(lines: 12, col: 1, row: 2)

        #expect(queue.enqueue(first) == first)
        #expect(queue.enqueue(.init(lines: 8, col: 3, row: 4)) == nil)
        #expect(queue.enqueue(.init(lines: -3, col: 5, row: 6)) == nil)

        let completed = queue.completeInFlight()
        let next = try #require(completed)
        #expect(next == LocalScrollbackScrollRequest(lines: 5, col: 5, row: 6))
        #expect(queue.completeInFlight() == nil)
        #expect(queue.isIdle)
    }

    @Test("drops pending movement that cancels before it is applied")
    func dropsCancelledPendingMovement() {
        var queue = LocalScrollbackScrollQueue()

        _ = queue.enqueue(.init(lines: 9, col: 1, row: 2))
        _ = queue.enqueue(.init(lines: 4, col: 3, row: 4))
        _ = queue.enqueue(.init(lines: -4, col: 5, row: 6))

        #expect(queue.completeInFlight() == nil)
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

    @Test("typed input can discard only the not-yet-applied movement")
    func discardsPendingMovement() {
        var queue = LocalScrollbackScrollQueue()

        _ = queue.enqueue(.init(lines: 10, col: 1, row: 2))
        _ = queue.enqueue(.init(lines: -3, col: 3, row: 4))
        queue.discardPending()

        #expect(queue.completeInFlight() == nil)
        #expect(queue.isIdle)
    }
}
#endif
