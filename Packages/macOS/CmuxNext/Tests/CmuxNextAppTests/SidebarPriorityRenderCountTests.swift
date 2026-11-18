import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The Priority view lists every agent chat on every machine with no cap, so it draws the rows in view
/// and one viewport each side, never a row per chat: at 100 chats as at 10,000 the same rows exist
/// (Leo 2026-11-18: "we draw the visible area, right?"). Each run prints its counts ("priority-counts").
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarPriorityRenderCountTests {
    /// `count` idle chats with no preview, so every row stands one height.
    static func entries(_ count: Int) -> [SidebarPriorityEntry] {
        (0..<count).map { SidebarPriorityEntry(id: "p\($0)", title: "chat \($0)", state: .idle) }
    }

    /// The panel showing `entries` in a window, laid out.
    static func shown(_ entries: [SidebarPriorityEntry]) -> (SidebarPriorityPanelView, NSWindow, Duration) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView = view
        let elapsed = ContinuousClock().measure {
            view.show(SidebarPriorityPanel(entries: entries))
            view.layoutSubtreeIfNeeded()
        }
        return (view, window, elapsed)
    }

    static func clip(of view: NSView) throws -> NSClipView {
        try #require(SidebarPriorityDragTests.scrollView(in: view)).contentView
    }

    /// The rows one viewport holds, times three (the viewport and one each side), and a partial row at each end.
    static func bound(_ clip: NSClipView) -> Int {
        Int((clip.bounds.height * 3 / SidebarPriorityRowView.height(hasPreview: false)).rounded(.up)) + 2
    }

    @Test(arguments: [100, 10_000])
    func mountedRowsStayWithinTheViewportAndItsOverscan(count: Int) throws {
        let (view, window, showTime) = Self.shown(Self.entries(count))
        defer { window.contentView = nil; window.closeAfterTest() }
        let clip = try Self.clip(of: view)
        #expect(clip.bounds.height > 0)
        let bound = Self.bound(clip)
        let alive = view.rows.count
        // One scroll step of a row, then a jump to the middle of the list.
        let step = SidebarPriorityRowView.height(hasPreview: false)
        let scrollTime = ContinuousClock().measure { clip.scroll(to: NSPoint(x: 0, y: step)) }
        let afterStep = view.rows.count
        let middle = count / 2
        clip.scroll(to: NSPoint(x: 0, y: CGFloat(middle) * step))
        print("priority-counts n=\(count) bound=\(bound) rows_alive=\(alive) after_step=\(afterStep) after_jump=\(view.rows.count) show=\(showTime) scroll_step=\(scrollTime)")
        #expect(alive <= bound, "rows alive \(alive) at \(count) chats; at most \(bound)")
        #expect(afterStep <= bound)
        #expect(view.rows.count <= bound)
        #expect(view.rows["p\(middle)"] != nil, "the row scrolled to is drawn")
    }

    /// The panel's work since `before`.
    static func since(_ before: SidebarPriorityPanelView.Counts, _ view: SidebarPriorityPanelView) -> SidebarPriorityPanelView.Counts {
        let now = view.counts
        return .init(made: now.made - before.made, configured: now.configured - before.configured,
                     framed: now.framed - before.framed, ticked: now.ticked - before.ticked)
    }

    /// One chat's text changing configures its row alone and moves no row; one scroll step makes, configures and
    /// places only the rows it reveals.
    @Test(arguments: [100, 10_000])
    func oneChangeConfiguresOneRowAndAScrollStepOnlyTheRevealedRows(count: Int) throws {
        var entries = Self.entries(count)
        let (view, window, _) = Self.shown(entries)
        defer { window.contentView = nil; window.closeAfterTest() }
        let clip = try Self.clip(of: view)
        var before = view.counts
        entries[1].title = "renamed"
        view.show(SidebarPriorityPanel(entries: entries))
        view.layoutSubtreeIfNeeded()
        let change = Self.since(before, view)
        #expect(view.rows["p1"]?.entry.title == "renamed")

        before = view.counts
        clip.scroll(to: NSPoint(x: 0, y: SidebarPriorityRowView.height(hasPreview: false)))
        let step = Self.since(before, view)
        print("priority-counts n=\(count) change=\(change) scroll_step=\(step)")
        #expect(change == .init(made: 0, configured: 1, framed: 0, ticked: 0), "one title change: \(change)")
        #expect(step.made <= 2, "one row's scroll made \(step.made) rows")
        #expect(step.configured == step.made && step.framed == step.made, "a scroll step touched rows it did not reveal: \(step)")
    }

    /// A minute's tick redraws only the drawn rows whose working time reads differently: "5m" becomes "6m", "3h"
    /// stays, and no row out of view is touched.
    @Test(arguments: [100, 10_000])
    func aClockTickRedrawsOnlyTheRowsWhoseTimeChanged(count: Int) throws {
        let start = Date()
        let entries = (0..<count).map { index in
            let since = start.addingTimeInterval(index.isMultiple(of: 2) ? -310 : -(3 * 3600 + 600))
            return SidebarPriorityEntry(id: "p\(index)", title: "chat \(index)", state: .working(since: since))
        }
        let (view, window, _) = Self.shown(entries)
        defer { window.contentView = nil; window.closeAfterTest() }
        var before = view.counts
        view.tick(now: start)
        #expect(Self.since(before, view).ticked == 0, "a tick within the same minute redrew rows")
        before = view.counts
        view.tick(now: start.addingTimeInterval(60))
        let tick = Self.since(before, view)
        let minutes = view.rows.keys.filter { Int($0.dropFirst()).map { $0.isMultiple(of: 2) } == true }.count
        print("priority-counts n=\(count) tick=\(tick) drawn=\(view.rows.count) minute_rows=\(minutes)")
        #expect(minutes > 0)
        #expect(tick == .init(made: 0, configured: 0, framed: 0, ticked: minutes), "a minute's tick: \(tick)")
    }
}
