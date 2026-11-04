#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The S7 live-resize probe's page window steps (`liveResize.page_moved_*_pt`, FRAME OWNER REFACTOR S7): a step measures
/// how far each shown page window moved since the step before, matched by window (not by place), so a panel or a page
/// window that appears adds nothing; a step after another resize's only notes the frames. The window server check
/// (`liveResize.ws_*_lag_pt`) reads a window's frame in the window server's space, flipped from AppKit's.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PageWindowMovesTests {
    private static func window(_ rect: NSRect, panel: Bool = false) -> NSWindow {
        let made = panel ? NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        made.isReleasedWhenClosed = false
        made.orderFrontRegardless()
        return made
    }

    @Test func aStepMeasuresEachShownPageWindowsMoveSinceTheLastStep() throws {
        _ = NSApplication.shared
        let parent = Self.window(NSRect(x: 100, y: 100, width: 600, height: 400))
        let left = Self.window(NSRect(x: 100, y: 100, width: 300, height: 400))
        let right = Self.window(NSRect(x: 400, y: 100, width: 300, height: 400))
        let catcher = Self.window(NSRect(x: 395, y: 100, width: 10, height: 400), panel: true)
        defer { [catcher, right, left, parent].forEach { $0.close() } }
        for child in [left, right, catcher] { parent.addChildWindow(child, ordered: .above) }
        try #require(PageWindowMoves.pages(of: parent).count == 2, "SETUP: the two page windows do not show as pages")

        var moves = PageWindowMoves()
        #expect(moves.step(in: parent, at: 10.000) == nil, "the first step only notes the frames")
        #expect(moves.step(in: parent, at: 10.008) == 0, "nothing moved")
        left.setFrame(NSRect(x: 100, y: 100, width: 270, height: 400), display: false)
        #expect(moves.step(in: parent, at: 10.016) == 30, "the left page shrank by 30 pt")
        catcher.setFrame(NSRect(x: 345, y: 100, width: 10, height: 400), display: false)
        #expect(moves.step(in: parent, at: 10.024) == 0, "a panel is not a page window")
        right.setFrame(NSRect(x: 388, y: 100, width: 312, height: 400), display: false)
        left.setFrame(NSRect(x: 100, y: 100, width: 266, height: 400), display: false)
        #expect(moves.step(in: parent, at: 10.032) == 12, "the larger of the two moves, each window against its own frame")
        #expect(moves.step(in: parent, at: 10.400) == nil, "a step after another resize's only notes the frames")
        let added = Self.window(NSRect(x: 120, y: 120, width: 100, height: 100))
        defer { added.close() }
        parent.addChildWindow(added, ordered: .above)
        #expect(moves.step(in: parent, at: 10.408) == 0, "a page window that appeared did not move")

        let alone = Self.window(NSRect(x: 100, y: 600, width: 200, height: 100))
        defer { alone.close() }
        var none = PageWindowMoves()
        _ = none.step(in: alone, at: 10.0)
        #expect(none.step(in: alone, at: 10.008) == nil, "a window with no page window has nothing to measure")
    }

    @Test func theWindowServerSpaceCountsFromThePrimaryScreensTop() throws {
        #expect(PageWindowMoves.flipped(CGRect(x: 10, y: 100, width: 50, height: 20), primaryHeight: 1000)
                == CGRect(x: 10, y: 880, width: 50, height: 20))
        #expect(PageWindowMoves.edgeDistance(CGRect(x: 0, y: 0, width: 100, height: 50), CGRect(x: 2, y: 0, width: 91, height: 50)) == 7,
                "the right edge moved 7 pt, the left 2 pt")

        _ = NSApplication.shared
        let shown = Self.window(NSRect(x: 140, y: 160, width: 400, height: 300))
        defer { shown.close() }
        CATransaction.flush()
        let lag = PageWindowMoves.windowServerLag(of: shown)
        let windowLag = try #require(lag.window, "the window server does not list a shown window")
        #expect(windowLag <= 1, "a window placed once: the window server's frame is AppKit's, flipped (\(windowLag) pt apart)")
        #expect(lag.pages == nil, "no page window")
    }
}
#endif
