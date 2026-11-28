import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// In-tree pages: dividers are plain views with no catcher panels, and a scroll on a divider's grab strip goes to the
/// pane on the pointer's side of its line (plans/cmux-next/in-tree-pages.md, Dividers). With the mode off the handle
/// keeps today's behavior.
@MainActor @Suite(.closesItsWindows, .serialized) struct DividerHandleScrollTests {
    /// A pane that records the scrolls it gets and where.
    final class Pane: NSView {
        var scrolls: [NSPoint] = []
        // Where the scroll is in this pane's window, as a view reads it (a test event has no window of its own, so
        // AppKit gives its location in screen coordinates).
        override func scrollWheel(with event: NSEvent) {
            guard let window else { return }
            scrolls.append(DividerHandleView.windowPoint(of: event, in: window))
        }
    }

    struct Fixture {
        let window: NSWindow
        let left: Pane
        let right: Pane
        let handle: DividerHandleView
    }

    /// Two panes side by side and a vertical divider's 10-point grab strip over their shared edge at x = 400.
    private static func fixture() -> Fixture {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let left = Pane(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        let right = Pane(frame: NSRect(x: 400, y: 0, width: 400, height: 500))
        let handle = DividerHandleView(kind: .split(SplitID("split")), axis: .horizontal)
        handle.frame = NSRect(x: 395, y: 0, width: 10, height: 500)
        window.contentView?.addSubview(left)
        window.contentView?.addSubview(right)
        window.contentView?.addSubview(handle)
        window.orderFrontRegardless()
        return Fixture(window: window, left: left, right: right, handle: handle)
    }

    private static func scroll(at point: NSPoint, in window: NSWindow) -> NSEvent? {
        let screen = window.convertPoint(toScreen: point)
        let primary = NSScreen.screens.first?.frame.maxY ?? 0
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 0, wheel3: 0)
        else { return nil }
        cg.location = CGPoint(x: screen.x, y: primary - screen.y)
        return NSEvent(cgEvent: cg)
    }

    @Test func theSidePointIsJustPastTheBandOnThePointersSide() {
        let band = NSRect(x: 395, y: 0, width: 10, height: 500)
        #expect(DividerHandleView.sidePoint(of: NSPoint(x: 397, y: 120), bandInWindow: band, lineMid: 400, axis: .horizontal) == NSPoint(x: 394, y: 120))
        #expect(DividerHandleView.sidePoint(of: NSPoint(x: 403, y: 120), bandInWindow: band, lineMid: 400, axis: .horizontal) == NSPoint(x: 406, y: 120))
        let row = NSRect(x: 0, y: 245, width: 800, height: 10)
        #expect(DividerHandleView.sidePoint(of: NSPoint(x: 50, y: 247), bandInWindow: row, lineMid: 250, axis: .vertical) == NSPoint(x: 50, y: 244))
        #expect(DividerHandleView.sidePoint(of: NSPoint(x: 50, y: 253), bandInWindow: row, lineMid: 250, axis: .vertical) == NSPoint(x: 50, y: 256))
    }

    @Test func aScrollOnTheStripGoesToThePaneOnThePointersSide() throws {
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: false) }
        let f = Self.fixture()
        defer { f.window.close() }
        let leftSide = try #require(Self.scroll(at: NSPoint(x: 397, y: 200), in: f.window))
        f.handle.scrollWheel(with: leftSide)
        #expect(f.left.scrolls.count == 1 && f.right.scrolls.isEmpty, "a scroll left of the line went to \(f.right.scrolls.isEmpty ? "nothing" : "the right pane")")
        let rightSide = try #require(Self.scroll(at: NSPoint(x: 403, y: 200), in: f.window))
        f.handle.scrollWheel(with: rightSide)
        #expect(f.right.scrolls.count == 1)
        // The pane sees the pointer inside itself, at the row it was on.
        if let point = f.right.scrolls.first {
            #expect(point.x > 405 && abs(point.y - 200) <= 1, "the right pane got the scroll at \(point)")
        }
    }

    @Test func withTheModeOffTheStripKeepsItsScroll() throws {
        InTreePages.shared.setForTesting(requested: false)
        let f = Self.fixture()
        defer { f.window.close() }
        let event = try #require(Self.scroll(at: NSPoint(x: 397, y: 200), in: f.window))
        f.handle.scrollWheel(with: event)
        #expect(f.left.scrolls.isEmpty && f.right.scrolls.isEmpty)
    }
}
