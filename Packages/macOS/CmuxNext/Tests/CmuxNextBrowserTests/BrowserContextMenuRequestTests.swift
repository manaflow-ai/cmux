import CmuxNextBrowser
import Foundation
import Testing

/// A page's context-menu request answers the engine exactly once: with the chosen row, or with
/// nil when the host drops it unanswered (the engine would otherwise wait for the menu forever).
@Suite struct BrowserContextMenuRequestTests {
    /// Runs one pass of the main run loop without waiting; the empty block keeps the default
    /// mode from being empty.
    private func runMainRunLoopPass() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {}
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
    }

    @Test func aRequestReleasedUnansweredAnswersNilOnceOnMain() {
        var answers: [String] = []
        var request: BrowserContextMenuRequest? = BrowserContextMenuRequest(
            items: [], target: BrowserContextMenuTarget(), location: .zero
        ) { id in
            answers.append((id.map { "\($0)" } ?? "nil") + (Thread.isMainThread ? "" : " off main"))
        }
        #expect(request != nil)
        request = nil
        runMainRunLoopPass()
        #expect(answers == ["nil"])
        runMainRunLoopPass()
        #expect(answers == ["nil"])
    }

    @Test func anAnsweredRequestIsNotAnsweredAgain() {
        var answers: [Int?] = []
        var request: BrowserContextMenuRequest? = BrowserContextMenuRequest(
            items: [], target: BrowserContextMenuTarget(), location: .zero
        ) { answers.append($0) }
        request?.complete(7)
        request?.complete(8)
        request = nil
        runMainRunLoopPass()
        #expect(answers == [7])
    }
}
