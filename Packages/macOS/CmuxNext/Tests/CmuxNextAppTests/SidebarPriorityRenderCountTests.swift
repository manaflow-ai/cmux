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

    /// What one title change costs to show at base, averaged over 50 updates. Prints "priority-walk".
    @Test(arguments: [100, 10_000])
    func theWalkPerUpdateIsMeasured(count: Int) throws {
        var entries = Self.entries(count)
        let (view, window, _) = Self.shown(entries)
        defer { window.contentView = nil; window.closeAfterTest() }
        let updates = 50
        let show = ContinuousClock().measure {
            for index in 0..<updates {
                entries[1].title = "renamed \(index)"
                view.show(SidebarPriorityPanel(entries: entries))
            }
        }
        let micros = Double(show.components.seconds) * 1e6 + Double(show.components.attoseconds) / 1e12
        print("priority-walk n=\(count) show_us_per_update=\(Int(micros / Double(updates)))")
        #expect(view.rows["p1"]?.entry.title == "renamed \(updates - 1)")
    }
}
