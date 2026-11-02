import AppKit
@testable import CmuxNextTerminal
import Testing

/// A terminal's scroller is a plain view over the shared thin knob, not a scroll view: on macOS 26 a
/// scroll view tiles its clip view and lays out its scroll-edge pockets on every frame change, and in a
/// split's first frame that pass was the new pane's largest layout item (RESIZE VIDEOS F1).
@MainActor @Suite struct TerminalScrollerResizeTests {
    static func scrollViews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { ($0 is NSScrollView || $0 is NSClipView) ? [$0] : scrollViews(in: $0) }
    }

    @Test func aResizedTerminalLaysOutNoScrollView() {
        let host = TerminalHostView()
        host.setFrameSize(NSSize(width: 400, height: 300))
        host.layoutSubtreeIfNeeded()
        #expect(Self.scrollViews(in: host).isEmpty)
    }

    /// The knob a move through the scrollback shows: a quarter as long as the track for 100 of 400
    /// rows, at the offset's share of the rows above the last screen, and it takes clicks on itself only.
    @Test func aMoveThroughTheScrollbackShowsTheKnobWhereTheViewportIs() throws {
        let scroller = TerminalScroller()
        scroller.frame = scroller.strip(in: CGRect(x: 0, y: 0, width: 400, height: 300))
        scroller.update(TerminalScrollbar(totalRows: 400, offsetRows: 300, visibleRows: 100))
        #expect(!scroller.thin.isKnobShown, "output at the bottom is not a move")
        scroller.update(TerminalScrollbar(totalRows: 400, offsetRows: 150, visibleRows: 100))
        #expect(scroller.thin.isKnobShown)
        #expect(scroller.thin.knobProportion == 0.25)
        #expect(scroller.thin.doubleValue == 0.5)
        let knob = scroller.thin.rect(for: .knob)
        #expect(abs(knob.midY - scroller.bounds.midY) < 1, "half way down the track")
        let onKnob = CGPoint(x: scroller.frame.maxX - 4, y: scroller.frame.minY + knob.midY)
        #expect(scroller.hitTest(onKnob) === scroller.thin)
        #expect(scroller.hitTest(CGPoint(x: scroller.frame.maxX - 4, y: scroller.frame.minY + 4)) == nil)
    }

    /// A knob drag scrolls the terminal to the row the knob points at; nothing to scroll hides it.
    @Test func aKnobDragScrollsToItsRowAndAFittingScreenHidesIt() {
        let scroller = TerminalScroller()
        scroller.frame = scroller.strip(in: CGRect(x: 0, y: 0, width: 400, height: 300))
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(TerminalScrollbar(totalRows: 400, offsetRows: 0, visibleRows: 100))
        scroller.thin.doubleValue = 0.5
        _ = scroller.thin.sendAction(scroller.thin.action, to: scroller.thin.target)
        scroller.thin.doubleValue = 1
        _ = scroller.thin.sendAction(scroller.thin.action, to: scroller.thin.target)
        #expect(rows == [150, 300])
        scroller.update(TerminalScrollbar(totalRows: 80, offsetRows: 0, visibleRows: 100))
        #expect(scroller.thin.isHidden)
        #expect(scroller.hitTest(CGPoint(x: scroller.frame.midX, y: scroller.frame.midY)) == nil)
    }
}
