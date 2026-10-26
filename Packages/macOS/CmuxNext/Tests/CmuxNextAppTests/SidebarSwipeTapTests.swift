import AppKit
import CoreGraphics
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// p04-input-100: the sidebar list and the spaces bar page from the input tap's scroll
/// observer, before AppKit dispatches the event, so `scrollWheel` no longer has to see every
/// event of a gesture (responsive scrolling, p03-110, stops calling it after the first).
@MainActor
struct SidebarSwipeTapTests {
    /// A stand-in for `InputEventTap`: one window-scoped scroll subscription per view, called
    /// as `sendEvent` calls it (the predicate, then the handler when it accepts).
    @MainActor final class FakeTap: SidebarScrollTap {
        final class Token {
            let window: NSWindow
            let predicate: @MainActor (NSEvent) -> Bool
            let handler: @MainActor (NSEvent) -> Void
            init(window: NSWindow, predicate: @escaping @MainActor (NSEvent) -> Bool, handler: @escaping @MainActor (NSEvent) -> Void) {
                self.window = window
                self.predicate = predicate
                self.handler = handler
            }
        }

        private var tokens: [Weak] = []
        private struct Weak { weak var token: Token? }

        var live: [Token] { tokens.compactMap(\.token) }

        func observeScrolls(in window: NSWindow, where predicate: @escaping @MainActor (NSEvent) -> Bool,
                            handler: @escaping @MainActor (NSEvent) -> Void) -> AnyObject {
            let token = Token(window: window, predicate: predicate, handler: handler)
            tokens.append(Weak(token: token))
            return token
        }

        /// Delivers `event` to one subscription as the tap does once its predicate accepted it
        /// (the predicate's hit test is covered on `SidebarSwipeInput.claims`).
        func deliver(_ event: NSEvent, to token: Token) { token.handler(event) }
    }

    /// A synthesized scroll event. Pixel units are a trackpad (precise deltas); line units a wheel.
    static func event(dx: Int32 = 0, dy: Int32 = 0, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none,
                      units: CGScrollEventUnit = .pixel) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
        if units == .pixel { cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
        if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        return NSEvent(cgEvent: cg)!
    }

    struct Harness {
        let sidebar: SidebarView
        let window: NSWindow
        let tap: FakeTap
    }

    private static func harness() -> Harness {
        _ = NSApplication.shared
        let model = SidebarModel(sections: [])
        model.profiles = [SidebarProfile(id: ProfileKey("work"), name: "Work"), SidebarProfile(id: ProfileKey("home"), name: "Home")]
        model.activeProfileID = ProfileKey("work")
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        let tap = FakeTap()
        sidebar.scrollTap = tap
        return Harness(sidebar: sidebar, window: window, tap: tap)
    }

    /// The live subscriptions to the harness window; the list subscribes first.
    private static func tokens(_ harness: Harness) -> [FakeTap.Token] {
        harness.tap.live.filter { $0.window === harness.window }
    }

    @Test func theListAndTheBarEachSubscribeOnceToTheirWindow() {
        let harness = Self.harness()
        #expect(Self.tokens(harness).count == 2, "one scroll subscription for the list, one for the spaces bar")
        harness.sidebar.scrollTap = nil
        #expect(harness.tap.live.isEmpty, "dropping the tap releases both subscriptions")
    }

    @Test func noWindowNoSubscription() {
        let tap = FakeTap()
        let list = SidebarScrollView()
        list.scrollTap = tap
        #expect(tap.live.isEmpty, "a view in no window has nothing to observe")
    }

    @Test func aHorizontalSwipeFedThroughTheTapPagesOnceAndIsNotFedAgainByScrollWheel() throws {
        let harness = Self.harness()
        let list = harness.sidebar.scrollView
        var phases: [ProfileSwipeTracker.Phase] = []
        var deltas: [CGFloat] = []
        list.onHorizontalScroll = { phase, dx, _ in
            phases.append(phase)
            deltas.append(dx)
        }
        let token = try #require(Self.tokens(harness).first)
        let gesture = [Self.event(dx: -20, phase: .began), Self.event(dx: -20, phase: .changed), Self.event(phase: .ended)]
        for event in gesture {
            harness.tap.deliver(event, to: token)
            // AppKit then dispatches the same event to the view (no responsive scrolling): it
            // must not feed the tracker a second time.
            list.scrollWheel(with: event)
        }
        #expect(phases == [.began, .changed, .ended])
        #expect(deltas == [gesture[0].scrollingDeltaX, gesture[1].scrollingDeltaX, 0])
    }

    @Test func aSwipeTheTapSawPagesWhenScrollWheelSeesOnlyItsFirstEvent() throws {
        // Responsive scrolling: AppKit calls scrollWheel for the first event, then tracks the
        // gesture itself. The tap still sees every event.
        let harness = Self.harness()
        let list = harness.sidebar.scrollView
        var phases: [ProfileSwipeTracker.Phase] = []
        list.onHorizontalScroll = { phase, _, _ in phases.append(phase) }
        let token = try #require(Self.tokens(harness).first)
        let began = Self.event(dx: -30, phase: .began)
        harness.tap.deliver(began, to: token)
        list.scrollWheel(with: began)
        harness.tap.deliver(Self.event(dx: -30, phase: .changed), to: token)
        harness.tap.deliver(Self.event(phase: .ended), to: token)
        #expect(phases == [.began, .changed, .ended])
    }

    @Test func aWheelNotchFedThroughTheTapPagesOnceAndTheRestOfTheRollHolds() throws {
        let harness = Self.harness()
        let list = harness.sidebar.scrollView
        var pages: [Int] = []
        list.onWheelPage = { pages.append($0) }
        let token = try #require(Self.tokens(harness).first)
        let first = Self.event(dx: 1, units: .line)
        let second = Self.event(dx: 1, units: .line)
        harness.tap.deliver(first, to: token)
        list.scrollWheel(with: first)
        harness.tap.deliver(second, to: token)
        list.scrollWheel(with: second)
        #expect(pages == [first.scrollingDeltaX > 0 ? -1 : 1], "one roll pages one space")
    }

    @Test func aVerticalWheelPagesOverTheBarButNotOverTheList() throws {
        let harness = Self.harness()
        var listPages: [Int] = []
        var barPages: [Int] = []
        harness.sidebar.scrollView.onWheelPage = { listPages.append($0) }
        harness.sidebar.profileBar.onWheelPage = { barPages.append($0) }
        let tokens = Self.tokens(harness)
        try #require(tokens.count == 2)
        harness.tap.deliver(Self.event(dy: -1, units: .line), to: tokens[0])
        harness.tap.deliver(Self.event(dy: -1, units: .line), to: tokens[1])
        #expect(listPages.isEmpty, "up or down scrolls the list")
        #expect(barPages.count == 1, "nothing over the bar scrolls vertically, so the wheel pages")
    }

    @Test func withNoTapScrollWheelStillPages() {
        let list = SidebarScrollView()
        var phases: [ProfileSwipeTracker.Phase] = []
        list.onHorizontalScroll = { phase, _, _ in phases.append(phase) }
        for event in [Self.event(dx: -20, phase: .began), Self.event(dx: -20, phase: .changed), Self.event(phase: .ended)] {
            list.scrollWheel(with: event)
        }
        #expect(phases == [.began, .changed, .ended])
    }

    // MARK: the hit-test predicate

    @Test func aGestureLatchesToTheViewItBeganOver() {
        let input = SidebarSwipeInput(pagesVertically: false)
        #expect(input.claims(Self.event(dx: -5, phase: .began), hit: { true }))
        #expect(input.claims(Self.event(dx: -5, phase: .changed), hit: { false }), "the rest of the gesture follows its start")
        input.observe(Self.event(phase: .ended))
        #expect(input.claims(Self.event(momentum: .begin), hit: { true }) == false, "momentum after the end is not latched")
    }

    @Test func aGestureThatBeganElsewhereIsNotClaimed() {
        let input = SidebarSwipeInput(pagesVertically: false)
        #expect(input.claims(Self.event(dx: -5, phase: .began), hit: { false }) == false)
        #expect(input.claims(Self.event(dx: -5, phase: .changed), hit: { true }) == false)
    }

    @Test func aWheelNotchIsHitTestedEachTime() {
        let input = SidebarSwipeInput(pagesVertically: false)
        #expect(input.claims(Self.event(dx: 1, units: .line), hit: { true }))
        #expect(input.claims(Self.event(dx: 1, units: .line), hit: { false }) == false)
    }
}
