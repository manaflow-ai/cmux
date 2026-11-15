import Foundation
@testable import CmuxNextPages
import Testing
import WebKit

/// Lawrence, 2026-11-15 ("the first Cmd+F press misses", 2 of 20 fresh launches on cmux-lawrence-2 after the key-hold
/// fix): Cmd-F on a Markdown page sends the page its "find" command, and the page focuses its find field a moment
/// later, in its own turn. Letters typed in between reached the page first and went to the element focused before
/// (none: the document body), so the field opened empty; with 300 ms between Cmd-F and the letters, 20 of 20 opened.
/// The page's readiness now waits for that focus move (``PageInputReadiness/awaitFocusMove()``): the key router's
/// type-ahead keeps the letters and types them into the field once it has focus, as before a document's first focus.
@MainActor @Suite struct PageFocusMoveWaitTests {
    private func readyPage() -> PageInputReadiness {
        let readiness = PageInputReadiness(configuration: WKWebViewConfiguration())
        readiness.receive(["epoch": 1])
        readiness.receive(true)
        return readiness
    }

    @Test func keysWaitForTheFocusMoveAPageCommandAsksFor() {
        let readiness = readyPage()
        var ready = 0
        readiness.onReady = { ready += 1 }
        #expect(readiness.isReady, "a page whose field had focus is not ready: the test proves nothing")

        readiness.awaitFocusMove()
        #expect(!readiness.isReady, "a page about to focus its find field counts as ready: the letters typed now go to the body")
        readiness.receive(["epoch": 1])
        #expect(!readiness.isReady, "the same element again is no focus move")
        readiness.receive(["epoch": 2])
        #expect(readiness.isReady, "the find field took focus, but the queued letters still wait")
        #expect(ready == 1, "the type-ahead was not told: \(ready)")
    }

    /// A command that moves no focus (the find field already had it) holds no keys past the bound.
    @Test func aFocusMoveThatNeverComesEndsAtItsBound() async {
        let readiness = readyPage()
        readiness.focusMoveLimit = .milliseconds(30)
        readiness.awaitFocusMove()
        let deadline = ContinuousClock.now + .seconds(3)
        // test-only: polls for the bound's one-shot task, bounded by `deadline`
        while !readiness.isReady, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(readiness.isReady, "a focus move that never came kept the page's keys")
    }

    /// A page not ready yet (its document never focused an editable element) keeps waiting for that first focus.
    @Test func aPageNotReadyYetStaysNotReady() {
        let readiness = PageInputReadiness(configuration: WKWebViewConfiguration())
        readiness.awaitFocusMove()
        readiness.receive(["epoch": 1])
        #expect(!readiness.isReady, "a focus move made a page ready whose document never focused an editable element")
    }
}
