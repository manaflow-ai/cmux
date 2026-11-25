import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import Testing

/// Leo 2026-11-22: "hovering only doesnt show". This replaces Lawrence's 2026-11-12 rule (msg
/// 30795: moving the mouse over the strip reveals the scroller): the terminal's thin scroller
/// stays hidden, and unbuilt (TerminalScrollerLazyTests), under the pointer alone. A move through
/// the scrollback shows it, and the pointer over its strip then widens and holds it.
@MainActor @Suite struct TerminalScrollerHoverTests {
    /// 900 rows of scrollback with the viewport following the bottom: output, never a scroll.
    static let following = TerminalScrollbar(totalRows: 900, offsetRows: 876, visibleRows: 24)
    static let scrolledBack = TerminalScrollbar(totalRows: 900, offsetRows: 40, visibleRows: 24)
    static let hostFrame = CGRect(x: 0, y: 0, width: 600, height: 400)

    /// The scroller itself: hidden under the pointer at rest; a move shows it and the pointer widens it.
    @Test func thePointerOverTheStripRevealsNothingUntilAScroll() throws {
        let scroller = TerminalScroller()
        scroller.frame = scroller.strip(in: Self.hostFrame)
        scroller.tile()
        scroller.update(Self.following)
        let thin = try #require(scroller.verticalScroller as? ThinScroller)
        #expect(!thin.isKnobShown, "hidden at rest")
        thin.pointerMoved(to: CGPoint(x: scroller.bounds.midX, y: scroller.bounds.midY))
        #expect(!thin.isKnobShown, "the pointer over the strip shows nothing")
        scroller.update(Self.scrolledBack) // a move through the scrollback
        #expect(thin.isKnobShown, "a scroll shows it")
        #expect(thin.isKnobExpanded, "wide under the pointer, ready to grab")
        thin.pointerMoved(to: nil)
        #expect(!thin.isKnobExpanded)
    }

    /// A terminal with scrollback that nobody scrolled builds no scroller under the pointer.
    @Test func thePointerAtTheTrailingEdgeBuildsNoScroller() {
        let host = TerminalHostView()
        host.frame = Self.hostFrame
        host.layoutSubtreeIfNeeded()
        host.showScrollbar(Self.following)
        #expect(!host.hasScroller, "idle: nothing built, nothing shown")
    }
}
