import CmuxNextFocus
@testable import CmuxNextApp
import Testing

/// The queue's state goes through `cmux-focus-core` and back on every call, and
/// the rule ages text by the time its first key arrived. Swift has to carry that
/// time across the round trip, or queued keys never expire.
@MainActor
struct TypeAheadQueueTests {
    @Test func textOlderThanTwoSecondsIsDropped() {
        var queue = TypeAheadQueue()
        let start = ContinuousClock.now
        queue.append("ls", surface: "surface-1", now: start)
        #expect(queue.take(surface: "surface-1", now: start + .seconds(3)) == nil)
    }

    @Test func freshTextIsTakenOnce() {
        var queue = TypeAheadQueue()
        let start = ContinuousClock.now
        queue.append("ls", surface: "surface-1", now: start)
        #expect(queue.take(surface: "surface-1", now: start + .milliseconds(500)) == "ls")
        #expect(queue.take(surface: "surface-1", now: start + .milliseconds(600)) == nil)
    }
}
