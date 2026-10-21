import AppKit
@testable import CmuxNextDesign
import Testing

/// Every scrollable card (hover cards, the update card's popover, ...) shares one super-thin
/// scroller (2026-10-20): a 3 pt knob on no track, overlay, hidden at rest. It stays a card scroller
/// after the macOS "Show scroll bars" setting changes.
@MainActor
@Suite(.serialized)
struct CardScrollerTests {
    @Test func aCardScrollViewGetsTheSharedThinScroller() throws {
        defer { SystemScrollers.preferredStyleOverride = nil }
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.hasVerticalScroller = true
        SystemScrollers.followAsCard(scrollView)
        let scroller = try #require(scrollView.verticalScroller as? CardScroller)
        #expect(CardScroller.knobThickness <= 3)
        #expect(CardScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay) <= 8)
        #expect(scroller.knobRect(for: CGRect(x: 0, y: 10, width: 8, height: 40)).width == CardScroller.knobThickness)
        SystemScrollers.preferredStyleOverride = .legacy
        SystemScrollers.systemStyleDidChange()
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.verticalScroller is CardScroller)
    }
}
