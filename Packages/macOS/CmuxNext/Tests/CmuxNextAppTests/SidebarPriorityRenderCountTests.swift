import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxVisibleRows
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

    /// One chat's text changing configures its row alone and moves no row; one scroll step configures and places only
    /// the rows it reveals.
    @Test(arguments: [100, 10_000])
    func oneChangeConfiguresOneRowAndAScrollStepOnlyTheRevealedRows(count: Int) throws {
        var entries = Self.entries(count)
        let (view, window, _) = Self.shown(entries)
        defer { window.contentView = nil; window.closeAfterTest() }
        let clip = try Self.clip(of: view)
        _ = view.listWork.take()
        entries[1].title = "renamed"
        view.show(SidebarPriorityPanel(entries: entries))
        view.layoutSubtreeIfNeeded()
        let change = view.listWork.take()
        #expect(view.rows["p1"]?.entry.title == "renamed")

        clip.scroll(to: NSPoint(x: 0, y: SidebarPriorityRowView.height(hasPreview: false)))
        let step = view.listWork.take()
        print("priority-counts n=\(count) change=\(change) scroll_step=\(step)")
        #expect(change.rowsConfigured == 1 && change.rowsLaidOut == 0, "one title change: \(change)")
        #expect(step.rowsConfigured <= 2, "one row's scroll configured \(step.rowsConfigured) rows")
        #expect(step.rowsLaidOut == step.rowsConfigured, "a scroll step placed rows it did not reveal: \(step)")
    }

    /// What the whole-list walk (`VisibleRowsBaseline` "sidebar priority": compare and reindex every chat) costs per
    /// update: one title change shown, and the reindex alone, averaged over 50 updates. Prints "priority-walk".
    @Test(arguments: [100, 10_000])
    func theWalkPerUpdateIsMeasured(count: Int) throws {
        var entries = Self.entries(count)
        let (view, window, _) = Self.shown(entries)
        defer { window.contentView = nil; window.closeAfterTest() }
        let updates = 50
        let clock = ContinuousClock()
        let show = clock.measure {
            for index in 0..<updates {
                entries[1].title = "renamed \(index)"
                view.show(SidebarPriorityPanel(entries: entries))
            }
        }
        let reindex = clock.measure { for _ in 0..<updates { view.reindex() } }
        let micros = { (duration: Duration) in
            Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
        }
        print("priority-walk n=\(count) show_us_per_update=\(Int(micros(show) / Double(updates))) "
            + "reindex_us_per_update=\(Int(micros(reindex) / Double(updates)))")
        #expect(view.rows["p1"]?.entry.title == "renamed \(updates - 1)")
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
        _ = view.listWork.take()
        view.tick(now: start)
        #expect(view.listWork.take().rowsConfigured == 0, "a tick within the same minute redrew rows")
        view.tick(now: start.addingTimeInterval(60))
        let tick = view.listWork.take()
        let minutes = view.rows.keys.filter { Int($0.dropFirst()).map { $0.isMultiple(of: 2) } == true }.count
        print("priority-counts n=\(count) tick=\(tick) drawn=\(view.rows.count) minute_rows=\(minutes)")
        #expect(minutes > 0)
        #expect(tick == .init(rowsConfigured: minutes), "a minute's tick: \(tick)")
    }
}
