import CmuxNextBrowser
import Foundation
import Testing

/// What a request answered, in order, and whether each answer came on the main thread.
private final class Answers {
    var list: [String] = []

    func record(_ id: Int?) {
        list.append((id.map { "\($0)" } ?? "nil") + (Thread.isMainThread ? "" : " off main"))
    }
}

/// A page's context-menu request answers the engine exactly once: with the chosen row, or with
/// nil when the host drops it unanswered (the engine would otherwise wait for the menu forever).
@Suite struct BrowserContextMenuRequestTests {
    /// Runs one pass of the main run loop without waiting; the empty block keeps the default
    /// mode from being empty.
    private func runMainRunLoopPass() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {}
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
    }

    private static func request(answeringInto answers: Answers) -> BrowserContextMenuRequest {
        BrowserContextMenuRequest(items: [], target: BrowserContextMenuTarget(), location: .zero) { answers.record($0) }
    }

    /// The nil answer is queued on the main run loop, never run inside the release: the code that
    /// dropped the request returns first.
    @Test func aRequestReleasedUnansweredAnswersNilOnceOnMainAfterTheRelease() {
        let answers = Answers()
        var request: BrowserContextMenuRequest? = Self.request(answeringInto: answers)
        #expect(request != nil)
        request = nil
        #expect(answers.list.isEmpty, "the release answered inline")
        runMainRunLoopPass()
        #expect(answers.list == ["nil"])
        runMainRunLoopPass()
        #expect(answers.list == ["nil"])
    }

    /// The last reference can drop on a background thread (an engine callback, a task): the
    /// request still answers nil, on main.
    @Test func aRequestReleasedOffMainAnswersNilOnMain() async {
        let answers = Answers()
        await Task.detached {
            let request = await BrowserContextMenuRequestTests.request(answeringInto: answers)
            // The task holds the only reference; it is released here, off the main thread.
            withExtendedLifetime(request) {}
        }.value
        runMainRunLoopPass()
        #expect(answers.list == ["nil"])
    }

    @Test func anAnsweredRequestIsNotAnsweredAgain() {
        let answers = Answers()
        var request: BrowserContextMenuRequest? = Self.request(answeringInto: answers)
        request?.complete(7)
        request?.complete(8)
        request = nil
        runMainRunLoopPass()
        #expect(answers.list == ["7"])
    }

    /// WebKit shows its own menu and waits for no answer, so its request has no completion:
    /// `complete` does nothing, and the release answers nothing and leaves the main run loop clean.
    @Test func aRequestWithoutACompletionTakesAnAnswerAndItsRelease() {
        var request: BrowserContextMenuRequest? = BrowserContextMenuRequest(
            items: [], target: BrowserContextMenuTarget(), location: .zero, completion: nil
        )
        request?.complete(7)
        request?.complete(nil)
        request = nil
        runMainRunLoopPass()
        runMainRunLoopPass()
        #expect(request == nil)
    }
}
