import CmuxNextSignposts
@testable import CmuxNextBrowser
import Foundation
import Testing

/// A new browser tab's `create.tab` end (p09-observability task 030): ``BrowserFirstContentFrame`` runs each waiter
/// exactly once, with true at the page's first content frame or false when it closes first; a WebKit tab reports
/// that frame on a failed load and a crashed page too (its error page or sad tab shows), so such a tab never waits
/// until it closes.
@MainActor @Suite(.serialized)
struct BrowserFirstContentFrameTests {
    @MainActor final class Results {
        private(set) var values: [Bool] = []
        var body: @MainActor (Bool) -> Void { { [self] in values.append($0) } }
    }

    @Test func eachWaiterRunsOnceWithTrueAtTheFirstContentFrame() {
        let frame = BrowserFirstContentFrame()
        let first = Results(), second = Results()
        frame.add(first.body)
        frame.add(second.body)
        #expect(first.values.isEmpty)
        frame.contentShown()
        frame.contentShown()
        frame.closed()
        #expect(first.values == [true])
        #expect(second.values == [true])
        #expect(frame.hasShownContent)
    }

    @Test func aWaiterAddedAfterTheFrameRunsAtOnceWithTrue() {
        let frame = BrowserFirstContentFrame()
        frame.contentShown()
        let late = Results()
        frame.add(late.body)
        #expect(late.values == [true])
    }

    @Test func aPageClosedFirstRunsItsWaitersOnceWithFalse() {
        let frame = BrowserFirstContentFrame()
        let waiting = Results()
        frame.add(waiting.body)
        frame.closed()
        frame.closed()
        frame.contentShown() // a paint after the close shows nothing
        #expect(waiting.values == [false])
        #expect(!frame.hasShownContent)
        let late = Results()
        frame.add(late.body)
        #expect(late.values == [false])
    }

    // MARK: WebKit's ends

    private func page() -> (WebKitTab, Results) {
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        let results = Results()
        page.whenFirstContentFrame(results.body)
        return (page, results)
    }

    @Test func aWebKitLoadThatFailsShowsItsErrorPageAsTheFirstFrame() {
        let (page, results) = page()
        defer { page.close() }
        // A newer navigation taking this one's place shows nothing yet.
        page.webView(page.webView, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
        #expect(results.values.isEmpty)
        page.webView(page.webView, didFailProvisionalNavigation: nil, withError: URLError(.cannotFindHost))
        #expect(results.values == [true])
    }

    @Test func aWebKitCommittedLoadThatFailsShowsAsTheFirstFrame() {
        let (page, results) = page()
        defer { page.close() }
        page.webView(page.webView, didFail: nil, withError: URLError(.networkConnectionLost))
        #expect(results.values == [true])
    }

    @Test func aWebKitContentProcessCrashShowsTheSadTabAsTheFirstFrame() {
        let (page, results) = page()
        defer { page.close() }
        page.webViewWebContentProcessDidTerminate(page.webView)
        #expect(results.values == [true])
    }

    @Test func aWebKitTabClosedFirstEndsItsWaitAsClosed() {
        let (page, results) = page()
        page.close()
        #expect(results.values == [false])
    }

    /// The adapter ``CreateTabTimings`` reads: a page that loads a document waits for its frame, and the page's end
    /// is the interval's outcome.
    @Test func theCreateTabAdapterMapsThePagesEnds() {
        let frame = BrowserFirstContentFrame()
        let reporter = Reporter(frame: frame)
        let outcomes = Outcomes()
        _ = reporter.createTabFirstFrame(content: reporter).wait(outcomes.done)
        #expect(outcomes.values.isEmpty)
        frame.contentShown()
        #expect(outcomes.values == [.shown])

        let closing = Reporter(frame: BrowserFirstContentFrame())
        _ = closing.createTabFirstFrame(content: closing).wait(outcomes.done)
        closing.frame.closed()
        #expect(outcomes.values == [.shown, .closed])

        let blank = Reporter(frame: BrowserFirstContentFrame(), loadsDocument: false)
        _ = blank.createTabFirstFrame(content: blank).wait(outcomes.done)
        #expect(outcomes.values == [.shown, .closed, .shown], "a blank page shows as it is (at the commit CreateTabTimings waits for)")
    }

    @MainActor final class Outcomes {
        private(set) var values: [CreateTabInterval.Outcome] = []
        var done: @MainActor (CreateTabInterval.Outcome) -> Void { { [self] in values.append($0) } }
    }

    @MainActor final class Reporter: BrowserFirstContentFrameReporting {
        let frame: BrowserFirstContentFrame
        let loadsDocument: Bool

        init(frame: BrowserFirstContentFrame, loadsDocument: Bool = true) {
            self.frame = frame
            self.loadsDocument = loadsDocument
        }

        func whenFirstContentFrame(_ body: @escaping @MainActor (Bool) -> Void) { frame.add(body) }
    }
}
