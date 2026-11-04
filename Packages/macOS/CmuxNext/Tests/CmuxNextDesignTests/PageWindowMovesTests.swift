#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The S7 live-resize probe's page window steps (`liveResize.page_moved_*_pt`, FRAME OWNER REFACTOR S7): a step measures
/// how far each shown page window moved since the step before, matched by window (not by place), so a panel or a page
/// window that appears adds nothing; a step after another resize's only notes the frames. The window server check
/// (`liveResize.ws_*_moved_*_pt`) sees a window's move as AppKit made it, to within 4 pt, in its own space (no flip: on a
/// fleet display the window server's frame is AppKit's inset by 2-4 pt, and the inset changes between reads).
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

    @Test func theWindowServerSeesAMoveAsAppKitMadeIt() throws {
        #expect(PageWindowMoves.edgeDistance(CGRect(x: 0, y: 0, width: 100, height: 50), CGRect(x: 2, y: 0, width: 91, height: 50)) == 7,
                "the right edge moved 7 pt, the left 2 pt")

        _ = NSApplication.shared
        let shown = Self.window(NSRect(x: 140, y: 160, width: 400, height: 300))
        defer { shown.close() }
        CATransaction.flush()
        let number = shown.windowNumber
        let before = PageWindowMoves.windowServerFrames(of: shown)
        let listed = try #require(before[number], "the window server does not list a shown window")
        let appKitBefore = PageWindowMoves.appKitFrames(of: shown)
        // A live resize's step: the right edge 30 pt in, the bottom edge 12 pt up.
        shown.setFrame(NSRect(x: 140, y: 172, width: 370, height: 288), display: true)
        CATransaction.flush()
        let after = PageWindowMoves.windowServerFrames(of: shown)
        let appKitAfter = PageWindowMoves.appKitFrames(of: shown)
        #expect(PageWindowMoves.largestMove(from: appKitBefore, to: appKitAfter, of: [number]) == 30, "AppKit's step")
        let moved = PageWindowMoves.largestMove(from: before, to: after, of: [number])
        let seen = "window server \(listed) to \(String(describing: after[number])), AppKit \(String(describing: appKitBefore[number])) to \(shown.frame)"
        // On a fleet display the window server's frame is AppKit's inset by 2-4 pt, and the inset changes between reads
        // (step d3a1a966: 30 pt read 29; step 3dff5b8f on cmux14: 28, insets 4 then 2 pt).
        #expect(moved.map { $0 > 0 && abs($0 - 30) <= 4 } == true, "the window server's frame moved \(String(describing: moved)) pt: \(seen)")
        #expect(PageWindowMoves.largestMove(from: before, to: after, of: [number + 1_000_000]) == nil, "a window in neither read")
        #expect(PageWindowMoves.pages(of: shown).isEmpty && after.count == 1, "only the window: \(after)")
    }
}
#endif
