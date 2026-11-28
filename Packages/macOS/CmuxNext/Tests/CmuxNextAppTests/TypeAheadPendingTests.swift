import CmuxNextFocus
import Testing

/// `TypeAheadQueue.pending(for:)` runs for every key typed into a page. With no text queued for
/// the surface it answers false without the reducer's JSON round trip (typing-latency goal:
/// "A key typed in a cmux NEXT agent chat has its edit and render done within 4 ms"). These pin
/// that the fast answer is the rule's answer in every state.
@MainActor
struct TypeAheadPendingTests {
    @Test func emptyQueueHoldsNothing() {
        let queue = TypeAheadQueue()
        #expect(!queue.pending(for: "page-1"))
    }

    @Test func textForAnotherSurfaceIsNotPendingHere() {
        var queue = TypeAheadQueue()
        queue.append("ab", surface: "page-1", now: .now)
        #expect(queue.pending(for: "page-1"))
        #expect(!queue.pending(for: "page-2"))
    }

    @Test func deletedTextLeavesNothingPending() {
        var queue = TypeAheadQueue()
        queue.append("a", surface: "page-1", now: .now)
        queue.deleteBackward(surface: "page-1")
        #expect(!queue.pending(for: "page-1"))
    }

    @Test func takenTextLeavesNothingPending() {
        var queue = TypeAheadQueue()
        let start = ContinuousClock.now
        queue.append("abc", surface: "page-1", now: start)
        #expect(queue.take(surface: "page-1", now: start + .milliseconds(10)) == "abc")
        #expect(!queue.pending(for: "page-1"))
    }
}
