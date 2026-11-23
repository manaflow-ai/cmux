import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The sidebar's scrollbar thumb shows only while its view scrolls (and the fade after), never for
/// the pointer alone, so a press near the sidebar's edge at rest always grabs the resize divider.
/// Leo, ask-969743672d: "to be honest, when hovering your mouse to the sidebar, do you want to see
/// the thumb? claude code, you dont see it... unless you scroll first. hovering only doesnt show.
/// this completely eliminates the problem where for us right now, when you're near the thumb and the
/// sliding repositioner, it gets confused and sometimes goes to the thumb instead of the dragger."
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarScrollerShowsOnScrollOnlyTests {
    typealias HitMap = SidebarEdgeHitMapTests

    /// Where the knob would be drawn, in root coordinates, shown or not.
    static func knobSlot(_ f: HitMap.Fixture) -> CGRect {
        let slot = f.scroller.knobRect(for: f.scroller.rect(for: .knob), expanded: true)
        return f.scroller.convert(slot, to: f.root)
    }

    /// The pointer at `x, y` (root coordinates) as the scroller's own tracking area reports it.
    static func hover(_ f: HitMap.Fixture, x: CGFloat, y: CGFloat) {
        guard let host = f.scroller.superview else { return }
        f.scroller.pointerMoved(to: host.convert(CGPoint(x: x, y: y), from: f.root))
    }

    /// Every sidebar scroller beside the resize band (the list's and both pinned bands') takes no
    /// reveal on hover.
    @Test func everySidebarScrollerShowsOnlyOnScroll() throws {
        let f = try HitMap.fixture(scrolled: false)
        defer { f.window.close() }
        let sidebar = f.root.sidebar.sidebarView
        for scroll: NSScrollView in [sidebar.scrollView, sidebar.aboveScroll, sidebar.belowScroll] {
            let thin = try #require(scroll.verticalScroller as? ThinScroller)
            #expect(!thin.revealsNearPointerAtRest)
        }
    }

    /// Hovering the edge, the knob's column or the sidebar itself shows no knob.
    @Test func hoverAloneShowsNoThumb() throws {
        let f = try HitMap.fixture(scrolled: false)
        defer { f.window.close() }
        let slot = Self.knobSlot(f)
        let edge = f.root.sidebar.frame.maxX
        for x in stride(from: edge - 20, through: edge, by: 0.5) {
            Self.hover(f, x: x, y: slot.midY)
            #expect(!f.scroller.isKnobShown, "the pointer \(x - edge) pt from the edge revealed the knob")
        }
        // The pointer arriving over the sidebar (its hover chrome) shows no knob either.
        let sidebar = f.root.sidebar.sidebarView
        sidebar.setChromeRevealed(false)
        sidebar.setChromeRevealed(true)
        #expect(!f.scroller.isKnobShown)
        for scroll: NSScrollView in [sidebar.aboveScroll, sidebar.belowScroll] {
            #expect((scroll.verticalScroller as? ThinScroller)?.isKnobShown != true)
        }
    }

    /// At rest, with the pointer right over where the knob would be, every press in the band is the
    /// divider's and the cursor is the resize cursor: nothing near the edge goes to the thumb.
    @Test func atRestTheDividerTakesEveryPressNearTheThumb() throws {
        let f = try HitMap.fixture(scrolled: false)
        defer { f.window.close() }
        let slot = Self.knobSlot(f)
        let edge = f.root.sidebar.frame.maxX
        Self.hover(f, x: slot.midX, y: slot.midY)
        #expect(!f.scroller.isKnobShown)
        for y in [slot.minY + 1, slot.midY, slot.maxY - 1] {
            #expect(HitMap.width(of: .scroller, atY: y, in: f) == 0, "a press at y \(y) went to the hidden thumb")
            for offset: CGFloat in [-1.5, -0.5, 0.5, 2, 4, 5.5] {
                #expect(HitMap.target(atX: edge + offset, y: y, in: f) == .resize, "a press \(offset) pt from the edge")
                #expect(f.handle.showsResizeCursor(at: f.root.convert(CGPoint(x: edge + offset, y: y), to: nil)))
            }
            #expect(HitMap.width(of: .resize, atY: y, in: f) >= 8)
        }
    }

    /// A scroll shows the thin knob; the pointer then holds and widens it so it can be grabbed.
    @Test func aScrollShowsTheThumbAndThePointerThenWidensIt() throws {
        let f = try HitMap.fixture(scrolled: false)
        defer { f.window.close() }
        let scrollView = try #require(f.scroller.superview as? NSScrollView)
        f.scroller.notificationCenter.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        #expect(f.scroller.isKnobShown)
        #expect(!f.scroller.isKnobExpanded)
        let slot = Self.knobSlot(f)
        Self.hover(f, x: slot.midX, y: slot.midY)
        #expect(f.scroller.isKnobExpanded)
        #expect(HitMap.target(atX: slot.midX, y: slot.midY, in: f) == .scroller)
    }
}
