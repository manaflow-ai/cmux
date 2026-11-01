import CmuxNextFocus
@testable import CmuxNextApp
@testable import CmuxNextPages
import Testing

/// Deletes typed into a new workspace's page while its type-ahead text is being inserted (Leo
/// 2026-10-22: "these new workspace deletions ... it's really slow and it's missing a LOT"). Once
/// the router has taken the queued text for the page, the queue is empty until the insert lands;
/// a Delete in that window found nothing to delete and was swallowed. It counts for that text now
/// and goes to the page after it.
@MainActor
struct TypeAheadDeleteTests {
    @Test func deletesWhileTheTakenTextIsDeliveredAreKeptForThePage() {
        var queue = TypeAheadQueue()
        let start = ContinuousClock.now
        queue.append("fix the bulid", surface: "page-1", now: start)
        #expect(queue.take(surface: "page-1", now: start + .milliseconds(50)) == "fix the bulid")
        for _ in 0..<4 { queue.deleteBackward(surface: "page-1", delivering: true) }
        #expect(queue.takeDeletes() == 4)
        #expect(queue.takeDeletes() == 0)
    }

    @Test func deletesWithTextStillQueuedEditTheQueue() {
        var queue = TypeAheadQueue()
        let start = ContinuousClock.now
        queue.append("lss", surface: "page-1", now: start)
        queue.deleteBackward(surface: "page-1", delivering: true)
        #expect(queue.takeDeletes() == 0)
        #expect(queue.take(surface: "page-1", now: start + .milliseconds(50)) == "ls")
    }

    @Test func aDeleteWithNothingOnItsWayIsNotKept() {
        var queue = TypeAheadQueue()
        queue.deleteBackward(surface: "page-1", delivering: false)
        #expect(queue.takeDeletes() == 0)
    }

    @Test func droppingTheQueueDropsItsDeletes() {
        var queue = TypeAheadQueue()
        queue.deleteBackward(surface: "page-1", delivering: true)
        queue.drop()
        #expect(queue.takeDeletes() == 0)
    }

    @Test func droppingWaitingTextKeepsDeletesForTakenText() {
        var queue = TypeAheadQueue()
        let start = ContinuousClock.now
        queue.append("fix the bulid", surface: "page-1", now: start)
        #expect(queue.take(surface: "page-1", now: start + .milliseconds(50)) == "fix the bulid")
        queue.deleteBackward(surface: "page-1", delivering: true)
        queue.dropPendingText()
        #expect(queue.takeDeletes() == 1)
    }

    /// The page gets one `delete` per key, after the element check, as typed keys would.
    @Test func thePageScriptDeletesOncePerKey() {
        let script = PageInputReadiness.editScript(.deleteBackward(3))
        #expect(script.contains("if (!editable(el)) { return false; }"))
        #expect(script.contains("i < 3"))
        #expect(script.contains("execCommand('delete', false)"))
        #expect(PageInputReadiness.editScript(.insert("a\"b")).contains(#"execCommand('insertText', false, "a\"b")"#))
    }
}
