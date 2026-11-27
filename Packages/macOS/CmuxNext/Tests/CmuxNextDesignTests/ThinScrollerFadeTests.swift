import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextWakeupsTestSupport

/// Lawrence 2026-10-23 (msg 11494): "the scrollbar stuff needs to be fixed so it auto-fades away,
/// and grows bigger on near-hover so it's easier to grab". The shared thin scroller (sidebar, hover
/// cards, Priority view, terminal) is a macOS overlay scroller: hidden at rest, shown while the view
/// scrolls and for a moment after, shown and wide while the pointer is near the trailing edge or the
/// knob is dragged, and it takes clicks only on the drawn knob.
@MainActor
@Suite(.serialized)
struct ThinScrollerFadeTests {
    /// A scroll view whose content is four times its height, with the shared thin scroller on
    /// `clock`, scrolled to the top.
    private static func scrollView(clock: ManualClock = ManualClock()) -> (NSScrollView, ThinScroller) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = ThinScroller(frame: .zero, clock: clock, notificationCenter: NotificationCenter())
        SystemScrollers.followThin(scrollView)
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 800))
        scrollView.tile()
        let scroller = scrollView.verticalScroller as! ThinScroller
        scroller.isEnabled = true
        scroller.knobProportion = 0.25
        return (scrollView, scroller)
    }

    @Test func theKnobIsHiddenAtRestByDefault() {
        #expect(SystemScrollers.thinScrollersAutoHide)
        let (_, scroller) = Self.scrollView()
        #expect(scroller.autoHides)
        #expect(!scroller.isKnobShown)
    }

    /// What AppKit posts while the user scrolls a scroll view (wheel, trackpad, a knob drag).
    private static func userScroll(_ scrollView: NSScrollView, center: NotificationCenter) {
        center.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
    }

    @Test func scrollingShowsTheKnobAndItFadesAfterTheRestDelay() async throws {
        let clock = ManualClock()
        let (scrollView, scroller) = Self.scrollView(clock: clock)
        scroller.doubleValue = 0.5 // the app or a layout moved it: no knob
        #expect(!scroller.isKnobShown)
        Self.userScroll(scrollView, center: scroller.notificationCenter)
        #expect(scroller.isKnobShown)
        #expect(!scroller.isKnobExpanded) // thin while it only scrolls
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(400))
        #expect(scroller.isKnobShown) // not yet
        // A new scroll step restarts the rest delay.
        Self.userScroll(scrollView, center: scroller.notificationCenter)
        try await clock.waitForSleeper()
        clock.advance(by: ThinScroller.restDelay)
        await scroller.restTask?.value
        #expect(!scroller.isKnobShown)
    }

    @Test func thePointerNearTheEdgeShowsAndWidensTheKnob() throws {
        let (scrollView, scroller) = Self.scrollView()
        let far = CGPoint(x: 40, y: 100)
        let near = CGPoint(x: scrollView.bounds.maxX - ThinScroller.nearDistance + 4, y: 100)
        scroller.pointerMoved(to: far)
        #expect(!scroller.isKnobShown)
        scroller.pointerMoved(to: near)
        #expect(scroller.isKnobShown)
        #expect(scroller.isKnobExpanded)
        let knob = try #require(scroller.restingKnobFrame)
        #expect(knob.width == ThinScroller.expandedKnobThickness)
        #expect(ThinScroller.expandedKnobThickness > ThinScroller.knobThickness * 2)
        #expect(knob.maxX == scroller.bounds.maxX - 2)
        scroller.pointerMoved(to: far)
        #expect(!scroller.isKnobShown)
        scroller.pointerMoved(to: near)
        scroller.pointerMoved(to: nil) // the pointer left the view
        #expect(!scroller.isKnobShown)
    }

    @Test func aDragKeepsTheKnobWideAndItStaysAMomentAfter() async throws {
        let clock = ManualClock()
        let (_, scroller) = Self.scrollView(clock: clock)
        var presence = scroller.presence
        presence.drag(true)
        #expect(presence.shown && presence.expanded)
        presence.drag(false)
        #expect(presence.shown && !presence.expanded) // the end of a drag counts as a scroll
        presence.rested()
        #expect(!presence.shown)
    }

    /// The terminal: the pointer does not reveal a knob at rest (the last column is the
    /// terminal's), but it holds and widens one a scroll showed, so it can be grabbed.
    @Test func withoutRevealAtRestThePointerOnlyHoldsAShownKnob() async throws {
        let clock = ManualClock()
        let (scrollView, scroller) = Self.scrollView(clock: clock)
        scroller.revealsNearPointerAtRest = false
        scroller.showsOnScroll = false
        let near = CGPoint(x: scrollView.bounds.maxX - 3, y: 100)
        scroller.pointerMoved(to: near)
        #expect(!scroller.isKnobShown)
        Self.userScroll(scrollView, center: scroller.notificationCenter) // the terminal shows it only for moves through its scrollback
        #expect(!scroller.isKnobShown)
        scroller.pointerMoved(to: nil)
        scroller.flash() // a move through the scrollback
        #expect(scroller.isKnobShown)
        scroller.pointerMoved(to: near)
        #expect(scroller.isKnobExpanded)
        try await clock.waitForSleeper()
        clock.advance(by: ThinScroller.restDelay)
        await scroller.restTask?.value
        #expect(scroller.isKnobShown) // held while the pointer stays near
        scroller.pointerMoved(to: nil)
        #expect(!scroller.isKnobShown)
    }

    @Test func clicksLandOnlyOnTheShownKnob() throws {
        let (scrollView, scroller) = Self.scrollView()
        let knobCenter = { () -> CGPoint in
            let knob = scroller.knobRect(for: scroller.rect(for: .knob), expanded: true)
            return scroller.convert(CGPoint(x: knob.midX, y: knob.midY), to: scrollView)
        }
        #expect(scroller.hitTest(knobCenter()) == nil) // hidden at rest: the click is the content's
        scroller.flash()
        #expect(scroller.hitTest(knobCenter()) === scroller)
        // Beside the knob (the track below it) the click is the content's.
        let knob = scroller.knobRect(for: scroller.rect(for: .knob), expanded: true)
        let below = scroller.convert(CGPoint(x: knob.midX, y: knob.maxY + 40), to: scrollView)
        #expect(scroller.hitTest(below) == nil)
    }

    @Test func theOptOutKeepsTheKnobShownWhileTheContentOverflows() {
        defer { SystemScrollers.thinScrollersAutoHide = true }
        let (_, scroller) = Self.scrollView()
        SystemScrollers.thinScrollersAutoHide = false
        #expect(!scroller.autoHides)
        #expect(scroller.isKnobShown)
        #expect(!scroller.isKnobExpanded)
    }

    /// Reduce Motion: the grow snaps (no movement), and the knob still shows and hides.
    @Test func underReduceMotionTheKnobStillShowsAndWidens() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        #expect(!Motion.feedback.animatesMovement)
        let (scrollView, scroller) = Self.scrollView()
        scroller.pointerMoved(to: CGPoint(x: scrollView.bounds.maxX - 3, y: 100))
        #expect(scroller.restingKnobFrame?.width == ThinScroller.expandedKnobThickness)
    }
}
