import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import Testing

/// Lawrence 2026-11-12 (msg 30795): "for terminal, moving mouse close over the scrollbar should
/// make it appear; should not change anything about the idle state though". The terminal's thin
/// scroller stays hidden at rest (and unbuilt, TerminalScrollerLazyTests); the pointer over its
/// strip at the trailing edge shows it, wide and ready to drag, while there is scrollback, as a
/// macOS overlay scroller does, and it fades when the pointer leaves.
@MainActor @Suite struct TerminalScrollerHoverTests {
    /// 900 rows of scrollback with the viewport following the bottom: output, never a scroll.
    static let following = TerminalScrollbar(totalRows: 900, offsetRows: 876, visibleRows: 24)
    static let hostFrame = CGRect(x: 0, y: 0, width: 600, height: 400)

    static func thin(of host: TerminalHostView) -> ThinScroller? {
        TerminalScrollerLazyTests.scrollViews(in: host).first?.verticalScroller as? ThinScroller
    }

    /// The scroller itself: hidden at rest, shown and wide with the pointer over its strip, hidden again after.
    @Test func thePointerOverTheStripRevealsTheScroller() throws {
        let scroller = TerminalScroller()
        scroller.frame = scroller.strip(in: Self.hostFrame)
        scroller.tile()
        scroller.update(Self.following)
        let thin = try #require(scroller.verticalScroller as? ThinScroller)
        #expect(!thin.isKnobShown, "hidden at rest")
        thin.pointerMoved(to: CGPoint(x: scroller.bounds.midX, y: scroller.bounds.midY))
        #expect(thin.isKnobShown, "the pointer over the strip shows it")
        #expect(thin.isKnobExpanded, "wide, ready to grab")
        thin.pointerMoved(to: nil)
        #expect(!thin.isKnobShown, "it fades when the pointer leaves")
    }

    /// A terminal with scrollback that nobody scrolled has no scroller built; the pointer at the
    /// trailing edge builds it and shows it. Elsewhere over the terminal it builds nothing.
    @Test func thePointerAtTheTrailingEdgeOfATerminalWithScrollbackShowsTheScroller() throws {
        let host = TerminalHostView()
        host.frame = Self.hostFrame
        host.layoutSubtreeIfNeeded()
        host.showScrollbar(Self.following)
        #expect(!host.hasScroller, "idle: nothing built, nothing shown")
        host.pointerMoved(to: CGPoint(x: 300, y: 200))
        #expect(!host.hasScroller, "the middle of the terminal reveals nothing")
        host.pointerMoved(to: CGPoint(x: Self.hostFrame.maxX - 4, y: 200))
        let thin = try #require(Self.thin(of: host), "the pointer at the edge builds the scroller")
        #expect(thin.isKnobShown, "and shows it")
        #expect(thin.isKnobExpanded)
    }

    /// With nothing to scroll back through the edge shows nothing (the idle look is unchanged).
    @Test func withoutScrollbackTheEdgeShowsNothing() {
        let host = TerminalHostView()
        host.frame = Self.hostFrame
        host.layoutSubtreeIfNeeded()
        host.showScrollbar(TerminalScrollbar(totalRows: 24, offsetRows: 0, visibleRows: 24))
        host.pointerMoved(to: CGPoint(x: Self.hostFrame.maxX - 4, y: 200))
        #expect(!host.hasScroller)
    }
}
