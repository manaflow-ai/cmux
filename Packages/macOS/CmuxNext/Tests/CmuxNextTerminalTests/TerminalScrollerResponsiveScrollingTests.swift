import AppKit
@testable import CmuxNextTerminal
import Testing

/// The terminal's scroller stays off AppKit's responsive scrolling on purpose: every
/// wheel event over it is the terminal's, which moves Ghostty's viewport per event, so AppKit must not
/// take a gesture over and scroll the scroller's empty document instead.
@MainActor
struct TerminalScrollerResponsiveScrollingTests {
    @Test func wheelEventsStayTheTerminals() throws {
        #expect(!TerminalScroller.isCompatibleWithResponsiveScrolling)
        let scroller = TerminalScroller()
        scroller.frame = NSRect(x: 0, y: 0, width: 12, height: 100)
        scroller.tile()
        var forwarded = 0
        scroller.onWheel = { _ in forwarded += 1 }
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -6, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
        let origin = scroller.contentView.bounds.origin
        scroller.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
        #expect(forwarded == 1)
        #expect(scroller.contentView.bounds.origin == origin)
    }
}
