#if DEBUG
import AppKit
@testable import CmuxNextWakeups
import Testing

/// `debug.chat_open_trace` (``ChatOpenTrace``): what it reports as the open's first content and its
/// longest empty stretch is what the chat first-paint numbers rest on (Leo 2026-10-22: "flickers the
/// initial thing ... then it just goes to black screen for a while").
@MainActor
struct ChatOpenTraceTests {
    @Test func firstContentAndLongestEmptyComeFromTheSurfaceChanges() {
        var record = ChatOpenTrace.Record(id: 1, launch: false, armedAt: 100)
        record.marks[ChatOpenTrace.Mark.action.rawValue] = 100
        record.frames = [(100.010, .gone), (100.050, .held), (100.090, .cover), (100.400, .coverLeaving), (100.560, .page)]
        #expect(abs((record.firstContentMilliseconds ?? 0) - 400) < 0.5)
        // The cover ran from 90 ms to 400 ms: 310 ms with nothing of the chat on screen.
        #expect(abs(record.longestEmptyMilliseconds - 310) < 0.5)
    }

    @Test func anEmptyStretchStillOnScreenAtTheEndCounts() {
        var record = ChatOpenTrace.Record(id: 1, launch: false, armedAt: 0)
        record.marks[ChatOpenTrace.Mark.action.rawValue] = 0
        record.frames = [(0.010, .gone), (0.100, .cover)]
        record.endedAt = 2.100
        // A timed-out open still black at the end: 2 s of cover, not 0.
        #expect(abs(record.longestEmptyMilliseconds - 2_000) < 0.5)
    }

    @Test func onlyTheBoundPaneAndItsAncestorsMark() {
        let trace = ChatOpenTrace()
        #expect(trace.begin())
        let container = NSView()
        let pane = NSView()
        container.addSubview(pane)
        let other = NSView()
        #expect(trace.bind(view: pane, page: nil, surface: { .cover }, engine: { "test" }))
        trace.mark(.loadingLeft, view: other)
        #expect(!trace.has(.loadingLeft), "another pane's loading state counted as the traced chat's")
        trace.mark(.holdEnd, view: container)
        #expect(trace.has(.holdEnd), "a hold over the view holding the traced pane is the open's")
        let cover = NSView()
        pane.addSubview(cover)
        trace.mark(.loadingLeft, view: cover)
        #expect(trace.has(.loadingLeft), "the traced pane's own loading cover did not count")
        _ = trace.finish(timedOut: false)
    }

    @Test func onlyTheTracedPageIsTraced() {
        let trace = ChatOpenTrace()
        #expect(trace.begin())
        let traced = NSObject()
        let other = NSObject()
        trace.mark(.chromiumStart, page: traced)
        #expect(trace.isTraced(page: traced))
        #expect(!trace.isTraced(page: other), "another agent page would bind its Chromium pane")
        trace.makingTracedPage = true
        #expect(trace.takeMakingTracedPage())
        #expect(!trace.takeMakingTracedPage(), "a second Chromium page took the traced page's pane")
        _ = trace.finish(timedOut: false)
        #expect(!trace.isTraced(page: traced))
    }

    /// #36060: under load, a spare page warming during the open marked first and latched the trace, so
    /// the opened pane's bind was refused: no `pane_made`, no frame sampled, no first content (the
    /// subagent case's load arm, 0/5 valid). The first pane to bind is the open's, and its page with it.
    @Test func theOpenedPanesPageTakesOverFromAPageThatMarkedBeforeIt() {
        let trace = ChatOpenTrace()
        #expect(trace.begin())
        let spare = NSObject()
        let opened = NSObject()
        trace.mark(.navigationStart, page: spare)
        trace.mark(.pagePainted, page: spare)
        let pane = NSView()
        #expect(trace.bind(view: pane, page: opened, surface: { .cover }, engine: { "test" }), "the opened pane's bind was refused")
        #expect(trace.has(.paneMade))
        #expect(trace.isTraced(page: opened))
        #expect(!trace.isTraced(page: spare), "the spare stayed the traced page")
        #expect(!trace.has(.pagePainted), "the spare's paint counted as the opened chat's")
        #expect(!trace.has(.navigationStart), "the spare's navigation counted as the opened chat's")
        trace.mark(.pagePainted, page: opened)
        #expect(trace.has(.pagePainted))
        _ = trace.finish(timedOut: false)
    }

    @Test func aHeldOpenHasNoEmptyStretch() {
        var record = ChatOpenTrace.Record(id: 1, launch: false, armedAt: 0)
        record.marks[ChatOpenTrace.Mark.action.rawValue] = 0
        record.frames = [(0.010, .gone), (0.040, .held), (0.350, .page)]
        #expect(record.longestEmptyMilliseconds == 0)
        #expect(abs((record.firstContentMilliseconds ?? 0) - 350) < 0.5)
    }

    /// An existing chat opened on the warm spare page: that page painted its first frame while it
    /// warmed, before the trace armed, so no ``ChatOpenTrace/Mark/pagePainted`` comes in this open.
    /// The pane's painted answer for the chat (what ends its cover) is the page showing the chat;
    /// without it every adopted open read `page_empty` to the end, 0 of 5 valid (#36226).
    @Test func anAdoptedPageThatPaintedBeforeTheTraceShowsOnceThePaneHasPainted() {
        #expect(ChatOpenTrace.Surface.shownPage(paintedInOpen: false, paneHasPainted: true) == .page)
        #expect(ChatOpenTrace.Surface.shownPage(paintedInOpen: true, paneHasPainted: false) == .page)
        #expect(ChatOpenTrace.Surface.shownPage(paintedInOpen: false, paneHasPainted: false) == .pageEmpty)
    }

    @Test func aMarkKeepsItsFirstTimeAndOnlyTheTracedPageMarks() {
        let trace = ChatOpenTrace()
        #expect(trace.begin())
        #expect(!trace.begin(), "a second trace armed over a running one")
        let traced = NSObject()
        let other = NSObject()
        trace.mark(.committed, page: traced)
        trace.mark(.pagePainted, page: other)
        #expect(trace.has(.committed))
        #expect(!trace.has(.pagePainted), "another page's paint counted as the traced chat's")
        trace.chromiumPane = "cmux-page-a"
        trace.mark(.firstContentfulPaint, chromiumPane: "cmux-page-b")
        #expect(!trace.has(.firstContentfulPaint))
        trace.mark(.firstContentfulPaint, chromiumPane: "cmux-page-a")
        #expect(trace.has(.firstContentfulPaint))
        let record = trace.finish(timedOut: false)
        #expect(record != nil)
        #expect(!trace.isArmed)
        trace.mark(.loadingLeft)
        #expect(record?.milliseconds(.loadingLeft) == nil)
    }
}
#endif
