import CmuxNextFocus
import CmuxNextFocusUI
import Testing

/// Return typed into a page before its field could take keys (Lawrence 2026-11-10: "I type in
/// something and press Enter and if it's too early nothing happens"). The router queued the text
/// and then dropped it at Return, which went to the page alone. Return, and the keys after it,
/// now wait behind the text and run once it landed.
@MainActor
struct TypeAheadReturnTests {
    @Test func returnWaitsBehindQueuedTextAndRunsAfterItLanded() {
        var queue = TypeAheadQueue()
        var tail = TypeAheadTail<String>()
        let start = ContinuousClock.now
        queue.append("cmux.com", surface: "page-1", now: start)
        tail.hold("return", surface: "page-1", delivering: false)
        #expect(tail.holds("page-1"))
        #expect(queue.pending(for: "page-1"), "Return dropped the text typed before it")

        // The page turns ready: the text is taken, and the keys follow once nothing is on its way.
        #expect(queue.take(surface: "page-1", now: start + .milliseconds(50)) == "cmux.com")
        tail.textWasTaken(surface: "page-1")
        #expect(tail.settle(surface: "page-1") == ["return"])
        #expect(tail.settle(surface: "page-1").isEmpty, "the keys run once")
    }

    @Test func keysTypedAfterReturnKeepTheirOrder() {
        var tail = TypeAheadTail<String>()
        tail.hold("return", surface: "page-1", delivering: true)
        tail.hold("p", surface: "page-1", delivering: true)
        tail.hold("return", surface: "page-1", delivering: true)
        #expect(tail.settle(surface: "page-1") == ["return", "p", "return"])
    }

    /// Text that expired in the queue never reached the page: Return alone would submit an empty field.
    @Test func returnBehindTextThatNeverLandedIsDropped() {
        var tail = TypeAheadTail<String>()
        tail.hold("return", surface: "page-1", delivering: false)
        #expect(tail.settle(surface: "page-1").isEmpty)
        #expect(tail.isEmpty)
    }

    @Test func keysForAnotherPageAreDropped() {
        var tail = TypeAheadTail<String>()
        tail.hold("return", surface: "page-1", delivering: true)
        tail.hold("return", surface: "page-2", delivering: true)
        #expect(!tail.holds("page-1"))
        #expect(tail.settle(surface: "page-1").isEmpty)
        #expect(tail.settle(surface: "page-2") == ["return"])
    }

    /// Return and keypad Enter follow queued text; later keys follow Return; a chord or Escape never waits.
    @Test func onlyPlainReturnStartsTheTail() {
        var tail = TypeAheadTail<String>()
        #expect(tail.takes(keyCode: 36, chord: false, surface: "page-1", behindText: true))
        #expect(tail.takes(keyCode: 76, chord: false, surface: "page-1", behindText: true))
        #expect(!tail.takes(keyCode: 36, chord: false, surface: "page-1", behindText: false), "no text waits: Return goes on")
        #expect(!tail.takes(keyCode: 36, chord: true, surface: "page-1", behindText: true))
        #expect(!tail.takes(keyCode: 0, chord: false, surface: "page-1", behindText: true), "text is queued, not held")
        tail.hold("return", surface: "page-1", delivering: false)
        #expect(tail.takes(keyCode: 0, chord: false, surface: "page-1", behindText: true))
        #expect(!tail.takes(keyCode: 53, chord: false, surface: "page-1", behindText: true), "Escape cancels what waits")
        #expect(!tail.takes(keyCode: 0, chord: true, surface: "page-1", behindText: true))
        #expect(!tail.takes(keyCode: 0, chord: false, surface: "page-2", behindText: false))
    }
}
