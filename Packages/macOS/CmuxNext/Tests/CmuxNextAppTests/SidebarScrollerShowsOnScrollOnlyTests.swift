import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The pointer arriving over the sidebar (its hover chrome) shows no scrollbar thumb: a sidebar
/// knob shows only while its view scrolls. `SidebarEdgeHitMapTests` covers the pointer near the
/// edge and presses in the resize band; this covers the sidebar-wide hover reveal, which used to
/// flash every sidebar scroller.
/// Leo, ask-969743672d: "to be honest, when hovering your mouse to the sidebar, do you want to see
/// the thumb? claude code, you dont see it... unless you scroll first. hovering only doesnt show.
/// this completely eliminates the problem where for us right now, when you're near the thumb and the
/// sliding repositioner, it gets confused and sometimes goes to the thumb instead of the dragger."
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarScrollerShowsOnScrollOnlyTests {
    typealias HitMap = SidebarEdgeHitMapTests

    @Test func thePointerArrivingOverTheSidebarShowsNoThumb() throws {
        let previous = SystemScrollers.thinScrollersAutoHide
        SystemScrollers.thinScrollersAutoHide = true // the default, where the old flash ran
        defer { SystemScrollers.thinScrollersAutoHide = previous }
        let f = try HitMap.fixture(scrolled: false)
        defer { f.window.close() }
        let sidebar = f.root.sidebar.sidebarView
        #expect(!f.scroller.isKnobShown)
        sidebar.setChromeRevealed(false)
        sidebar.setChromeRevealed(true)
        for scroll: NSScrollView in [sidebar.scrollView, sidebar.aboveScroll, sidebar.belowScroll] {
            #expect((scroll.verticalScroller as? ThinScroller)?.isKnobShown != true, "hovering the sidebar showed a thumb")
        }
        // Every press at the edge on the knob's rows still resizes: no hidden knob takes it.
        let slot = f.scroller.convert(f.scroller.knobRect(for: f.scroller.rect(for: .knob), expanded: true), to: f.root)
        for y in [slot.minY + 1, slot.midY, slot.maxY - 1] {
            #expect(HitMap.width(of: .scroller, atY: y, in: f) == 0, "a press at y \(y) went to the hidden thumb")
        }
    }

    /// A real scroll still shows the knob after the sidebar's hover reveal.
    @Test func aScrollStillShowsTheThumb() throws {
        let f = try HitMap.fixture(scrolled: false)
        defer { f.window.close() }
        f.root.sidebar.sidebarView.setChromeRevealed(true)
        let scrollView = try #require(f.scroller.superview as? NSScrollView)
        f.scroller.notificationCenter.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        #expect(f.scroller.isKnobShown)
    }

    @Test func theGlobalPersistentThumbSettingDoesNotRevealTheSidebar() throws {
        let previous = SystemScrollers.thinScrollersAutoHide
        SystemScrollers.thinScrollersAutoHide = false
        defer { SystemScrollers.thinScrollersAutoHide = previous }
        let f = try HitMap.fixture(scrolled: false)
        defer { f.window.close() }
        let sidebar = f.root.sidebar.sidebarView
        sidebar.setChromeRevealed(true)
        for scroll: NSScrollView in [sidebar.scrollView, sidebar.aboveScroll, sidebar.belowScroll] {
            #expect((scroll.verticalScroller as? ThinScroller)?.autoHides == true)
            #expect((scroll.verticalScroller as? ThinScroller)?.isKnobShown != true,
                    "the persistent-thumb setting revealed a sidebar thumb")
        }
        let scrollView = try #require(f.scroller.superview as? NSScrollView)
        f.scroller.notificationCenter.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        #expect(f.scroller.isKnobShown, "a real sidebar scroll must still show the thumb")
    }
}
