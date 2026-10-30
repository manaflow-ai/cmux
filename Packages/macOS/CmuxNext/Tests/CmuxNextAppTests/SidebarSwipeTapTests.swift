import AppKit
import CmuxNextDesign
import CmuxNextInput
@testable import CmuxNextSidebar
import Testing

/// The sidebar's space paging hears the app's input tap, not `scrollWheel(with:)`: the list's
/// scroll view and the space bar each hold one passing scroll intercept while in a window with the tap; a
/// scroll an earlier intercept consumed (a hover card's) pages nothing; a
/// horizontal trackpad gesture that began over the view pages 1:1 and never scrolls; a vertical one scrolls; a
/// gesture that began elsewhere never pages; a wheel roll pages once and its rest is held; an event the tap never
/// fed scrolls. So responsive scrolling, which tracks a gesture without calling
/// `scrollWheel(with:)` per event, cannot take the paging away.
@MainActor @Suite(.serialized) struct SidebarSwipeTapTests {
    final class Harness {
        let tap = InputEventTap()
        let model = SidebarModel()
        let sidebar: SidebarView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        var scrolls: [(ProfileSwipeTracker.Phase, CGFloat)] = []
        var swipes: [Int] = []
        var pages: [Int] = []
        private var clock: UInt64 = 1_000_000_000

        init() {
            _ = NSApplication.shared
            model.profiles = [SidebarProfile(id: ProfileKey("work"), name: "Work"), SidebarProfile(id: ProfileKey("home"), name: "Home")]
            model.activeProfileID = ProfileKey("work")
            sidebar = SidebarView(model: model, design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            content.addSubview(sidebar)
            window.contentView = content
            sidebar.inputTap = tap
            sidebar.layoutSubtreeIfNeeded()
            for feed in [sidebar.scrollView.swipes, sidebar.profileBar.swipes] {
                feed.onHorizontalScroll = { [weak self] phase, dx, _ in self?.scrolls.append((phase, dx)) }
                feed.onWheelPage = { [weak self] step in self?.pages.append(step) }
            }
        }

        func close() { window.orderOut(nil) }

        var intercepts: Int { tap.subscriberCount(.scroll, stage: .intercept) }

        /// A trackpad scroll in `phase` (Quartz: began 1, changed 2, ended 4; momentum by `momentum`), with no window
        /// unless `at` places it in the harness's window (window coordinates; that needs a display).
        func trackpad(dx: Int32 = 0, dy: Int32 = 0, phase: Int64 = 0, momentum: Int64 = 0, at point: CGPoint? = nil) throws -> NSEvent {
            try event(units: .pixel, dx: dx, dy: dy, at: point) { cg in
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            }
        }

        /// A mouse wheel notch of `dx`, `dy` lines (no phase, no precise deltas).
        func wheel(dx: Int32 = 0, dy: Int32 = 0, at point: CGPoint? = nil) throws -> NSEvent {
            try event(units: .line, dx: dx, dy: dy, at: point) { _ in }
        }

        private func event(units: CGScrollEventUnit, dx: Int32, dy: Int32, at point: CGPoint?,
                           _ configure: (CGEvent) -> Void) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
            clock += 16_000_000 // each event its own timestamp, a trackpad's rate apart
            cg.timestamp = clock
            configure(cg)
            if let point {
                // Quartz's global coordinates start at the primary display's top left.
                let screenPoint = window.convertPoint(toScreen: point)
                cg.location = CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screenPoint.y)
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            }
            let event = try #require(NSEvent(cgEvent: cg))
            if point != nil { try #require(event.window === window, "the scroll does not name the sidebar's window") }
            return event
        }

        /// `event` through the tap's observe and intercept stages, as `CmuxApplication.sendEvent` delivers it
        /// before AppKit; whether an intercept consumed it.
        @discardableResult func deliver(_ event: NSEvent) -> InputEventTap.InterceptResult {
            var result = InputEventTap.InterceptResult.pass
            tap.dispatching {
                tap.deliverObserve(event)
                result = tap.deliverIntercepts(event)
            }
            return result
        }

        /// A point over the list, and one over the space bar, in window coordinates.
        var overList: CGPoint {
            let list = sidebar.scrollView
            return list.convert(NSPoint(x: list.bounds.midX, y: list.bounds.midY), to: nil)
        }
        var overBar: CGPoint {
            let bar = sidebar.profileBar
            return bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil)
        }
        var outside: CGPoint { CGPoint(x: 600, y: 300) }
    }

    /// Read off the main actor: Swift Testing evaluates `.enabled(if:)` in a Sendable closure, and
    /// `NSScreen.screens` is main-actor isolated, so this asks CoreGraphics for the active displays.
    nonisolated static var hasDisplay: Bool {
        var count: UInt32 = 0
        return CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
    }

    // MARK: Subscriptions

    @Test func theListAndTheBarEachHoldOneScrollInterceptWhileInAWindowWithTheTap() {
        let harness = Harness()
        defer { harness.close() }
        #expect(harness.intercepts == 2, "the list's scroll view and the space bar each hold one scroll intercept")
        #expect(harness.tap.subscriberCount(.scroll, stage: .observe) == 0,
                "the paging acts on a scroll, so it runs after the intercepts that may consume it, not as an observer")
        harness.sidebar.removeFromSuperview()
        #expect(harness.intercepts == 0, "a sidebar out of its window hears no scroll")
        harness.window.contentView?.addSubview(harness.sidebar)
        #expect(harness.intercepts == 2)
        harness.sidebar.inputTap = nil
        #expect(harness.intercepts == 0, "no tap, no intercept")
    }

    // MARK: The feed's decisions

    @Test func aHorizontalGesturePagesOneToOneAndNeverScrolls() throws {
        let harness = Harness()
        defer { harness.close() }
        let feed = harness.sidebar.scrollView.swipes
        let began = try harness.trackpad(dx: 10, phase: 1)
        let changed = try harness.trackpad(dx: 20, phase: 2)
        let ended = try harness.trackpad(phase: 4)
        for event in [began, changed] {
            feed.receive(event) { true }
            #expect(feed.takes(event), "the list scrolled a horizontal gesture")
        }
        feed.receive(ended) { true }
        #expect(harness.scrolls.map { $0.0 } == [.began, .changed, .ended])
        #expect(harness.scrolls.map { $0.1 } == [10, 20, 0])
        #expect(!feed.takes(ended), "a gesture's end goes on to the scroll view, as before")
    }

    @Test func aVerticalGestureScrollsAndPagesNothing() throws {
        let harness = Harness()
        defer { harness.close() }
        let feed = harness.sidebar.scrollView.swipes
        for (dy, phase) in [(Int32(12), Int64(1)), (24, 2), (0, 4)] {
            let event = try harness.trackpad(dy: dy, phase: phase)
            feed.receive(event) { true }
            #expect(!feed.takes(event), "the list did not scroll a vertical gesture")
        }
        #expect(harness.scrolls.isEmpty && harness.pages.isEmpty)
    }

    @Test func aGestureThatBeganElsewhereNeverPagesItsLaterEventsOrItsMomentum() throws {
        let harness = Harness()
        defer { harness.close() }
        let feed = harness.sidebar.scrollView.swipes
        var asked = 0
        feed.receive(try harness.trackpad(dx: 10, phase: 1)) { asked += 1; return false }
        for event in try [harness.trackpad(dx: 30, phase: 2), harness.trackpad(phase: 4), harness.trackpad(dx: 30, momentum: 1)] {
            feed.receive(event) { asked += 1; return true }
            #expect(!feed.takes(event))
        }
        #expect(asked == 1, "a gesture is hit tested at its first event only")
        #expect(harness.scrolls.isEmpty, "a gesture that began off the list paged the spaces")
    }

    @Test func aOneStepSwipeFiresOncePerGesture() throws {
        let harness = Harness()
        defer { harness.close() }
        let feed = harness.sidebar.profileBar.swipes
        feed.onHorizontalScroll = nil
        feed.onHorizontalSwipe = { [weak harness] step in harness?.swipes.append(step) }
        for (dx, phase) in [(Int32(-30), Int64(1)), (-40, 2), (-40, 2), (0, 4)] {
            feed.receive(try harness.trackpad(dx: dx, phase: phase)) { true }
        }
        #expect(harness.swipes == [1], "a leftward swipe goes to the next space, once")
    }

    @Test func aSidewaysWheelRollPagesOnceAndItsRestIsHeld() throws {
        let harness = Harness()
        defer { harness.close() }
        let feed = harness.sidebar.scrollView.swipes
        let first = try harness.wheel(dx: -1)
        let rest = try harness.wheel(dx: -1)
        feed.receive(first) { true }
        #expect(feed.takes(first), "the notch that paged scrolled the list")
        feed.receive(rest) { true }
        #expect(feed.takes(rest), "the rest of the roll scrolled the list")
        #expect(harness.pages == [1], "one roll pages once")
        let vertical = try harness.wheel(dy: -1)
        feed.receive(vertical) { true }
        #expect(!feed.takes(vertical), "a vertical wheel over the list must scroll it")
        #expect(harness.pages == [1])
    }

    @Test func aVerticalWheelOverTheBarPages() throws {
        let harness = Harness()
        defer { harness.close() }
        let feed = harness.sidebar.profileBar.swipes
        let notch = try harness.wheel(dy: -1)
        feed.receive(notch) { true }
        #expect(harness.pages == [1])
        #expect(feed.takes(notch))
    }

    @Test func aWheelNotchOffTheViewPagesNothing() throws {
        let harness = Harness()
        defer { harness.close() }
        let feed = harness.sidebar.profileBar.swipes
        let notch = try harness.wheel(dy: -1)
        feed.receive(notch) { false }
        #expect(harness.pages.isEmpty && !feed.takes(notch))
    }

    @Test func anEventTheTapNeverFedScrolls() throws {
        let harness = Harness()
        defer { harness.close() }
        let feed = harness.sidebar.scrollView.swipes
        feed.receive(try harness.trackpad(dx: 10, phase: 1)) { true }
        let unfed = try harness.trackpad(dx: 20, phase: 2)
        #expect(!feed.takes(unfed), "scrollWheel kept an event the paging never heard")
    }

    @Test func aScrollRoutesToTheViewOnlyThroughNoOtherScrollView() {
        let outer = NSView()
        let inner = NSScrollView()
        let leaf = NSView()
        let direct = NSView()
        outer.addSubview(inner)
        inner.addSubview(leaf)
        outer.addSubview(direct)
        #expect(SidebarSwipeFeed.routes(hit: direct, to: outer))
        #expect(SidebarSwipeFeed.routes(hit: outer, to: outer))
        #expect(!SidebarSwipeFeed.routes(hit: leaf, to: outer), "a scroll view inside the view takes the scroll first")
        #expect(SidebarSwipeFeed.routes(hit: leaf, to: inner))
        #expect(!SidebarSwipeFeed.routes(hit: outer, to: direct))
    }

    // MARK: Through the tap

    // skip-owner: PL-input; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
    @Test(.enabled(if: hasDisplay, "a windowed scroll's point needs a display"))
    func aSwipeOverTheListThroughTheTapPagesAndScrollWheelKeepsIt() throws {
        let harness = Harness()
        defer { harness.close() }
        harness.window.orderFrontRegardless()
        let began = try harness.trackpad(dx: 10, phase: 1, at: harness.overList)
        let changed = try harness.trackpad(dx: 20, phase: 2, at: harness.overList)
        let feed = harness.sidebar.scrollView.swipes
        // AppKit calls scrollWheel right after each event's tap delivery, so each event is asked about then.
        #expect(harness.deliver(began) == .pass, "the paging consumed a scroll; scrollWheel decides what scrolls")
        harness.deliver(changed)
        #expect(feed.takes(changed), "scrollWheel would scroll the list for a horizontal gesture")
        let ended = try harness.trackpad(phase: 4, at: harness.outside)
        harness.deliver(ended) // latched: it follows the fingers off the list
        #expect(!feed.takes(ended), "a gesture's end goes on to the scroll view, as before")
        #expect(harness.scrolls.map { $0.0 } == [.began, .changed, .ended])
    }

    // skip-owner: PL-input; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
    @Test(.enabled(if: hasDisplay, "a windowed scroll's point needs a display"))
    func aSwipeOverTheBarThroughTheTapPagesOnlyTheBar() throws {
        let harness = Harness()
        defer { harness.close() }
        harness.window.orderFrontRegardless()
        try #require(!harness.sidebar.profileBar.isHidden, "two spaces show the bar")
        harness.deliver(try harness.trackpad(dx: -10, phase: 1, at: harness.overBar))
        harness.deliver(try harness.trackpad(dx: -20, phase: 2, at: harness.overBar))
        #expect(harness.scrolls.map { $0.0 } == [.began, .changed], "the bar and the list must not both page one gesture")
    }

    // skip-owner: PL-input; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
    @Test(.enabled(if: hasDisplay, "a windowed scroll's point needs a display"))
    func aSwipeOrWheelOffTheSidebarThroughTheTapPagesNothing() throws {
        let harness = Harness()
        defer { harness.close() }
        harness.window.orderFrontRegardless()
        harness.deliver(try harness.trackpad(dx: 10, phase: 1, at: harness.outside))
        harness.deliver(try harness.trackpad(dx: 40, phase: 2, at: harness.overList))
        harness.deliver(try harness.wheel(dx: -1, at: harness.outside))
        #expect(harness.scrolls.isEmpty && harness.pages.isEmpty, "a scroll off the sidebar paged its spaces")
    }

    // skip-owner: PL-input; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
    @Test(.enabled(if: hasDisplay, "a windowed scroll's point needs a display"))
    func aSidewaysWheelRollOverTheListThroughTheTapPagesOnceAndScrollWheelKeepsIt() throws {
        let harness = Harness()
        defer { harness.close() }
        harness.window.orderFrontRegardless()
        let first = try harness.wheel(dx: -1, at: harness.overList)
        let rest = try harness.wheel(dx: -1, at: harness.overList)
        let feed = harness.sidebar.scrollView.swipes
        // AppKit calls scrollWheel right after each event's tap delivery, so each event is asked about then.
        harness.deliver(first)
        #expect(feed.takes(first), "scrollWheel would scroll the list for the notch that paged")
        harness.deliver(rest)
        #expect(feed.takes(rest), "scrollWheel would scroll the list for the rest of the roll")
        #expect(harness.pages == [1], "one sideways roll over the list pages once")
    }

    // skip-owner: PL-input; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
    @Test(.enabled(if: hasDisplay, "a windowed scroll's point needs a display"))
    func aScrollAnEarlierInterceptConsumedOverTheListPagesNothing() throws {
        let harness = Harness()
        defer { harness.close() }
        harness.window.orderFrontRegardless()
        // A hover card shown over the list takes the scrolls on it at `popup` (HoverCardCoordinator+Input).
        var cardHeard = 0
        let card = harness.tap.subscribe(class: .scroll, phase: .intercept(order: .popup)) { _ -> InputEventTap.InterceptResult in
            cardHeard += 1
            return .consume
        }
        defer { card.cancel() }
        let notch = try harness.wheel(dx: -1, at: harness.overList)
        #expect(harness.deliver(notch) == .consume)
        #expect(!harness.sidebar.scrollView.swipes.takes(notch))
        let changed = try harness.trackpad(dx: 20, phase: 2, at: harness.overList)
        harness.deliver(try harness.trackpad(dx: 10, phase: 1, at: harness.overList))
        harness.deliver(changed)
        #expect(!harness.sidebar.scrollView.swipes.takes(changed))
        #expect(cardHeard == 3)
        #expect(harness.pages.isEmpty && harness.scrolls.isEmpty, "a scroll the card consumed also paged the spaces")
    }

    // skip-owner: PL-input; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
    @Test(.enabled(if: hasDisplay, "a windowed scroll's point needs a display"))
    func aVerticalWheelOverTheBarThroughTheTapPages() throws {
        let harness = Harness()
        defer { harness.close() }
        harness.window.orderFrontRegardless()
        try #require(!harness.sidebar.profileBar.isHidden, "two spaces show the bar")
        let notch = try harness.wheel(dy: -1, at: harness.overBar)
        harness.deliver(notch)
        #expect(harness.pages == [1], "a vertical notch over the bar pages once, and only the bar pages it")
        #expect(harness.sidebar.profileBar.swipes.takes(notch))
    }

    // skip-owner: PL-input; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
    @Test(.enabled(if: hasDisplay, "a windowed scroll's point needs a display"))
    func aVerticalWheelOverTheListThroughTheTapScrollsAndPagesNothing() throws {
        let harness = Harness()
        defer { harness.close() }
        harness.window.orderFrontRegardless()
        let notch = try harness.wheel(dy: -1, at: harness.overList)
        harness.deliver(notch)
        #expect(harness.pages.isEmpty, "a vertical notch over the list paged the spaces")
        #expect(!harness.sidebar.scrollView.swipes.takes(notch), "scrollWheel would not scroll the list for a vertical notch")
    }

    // skip-owner: PL-input; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
    @Test(.enabled(if: hasDisplay, "a windowed scroll's point needs a display"))
    func aWheelInAnotherWindowThroughTheTapPagesNothing() throws {
        let harness = Harness()
        let other = Harness()
        defer { harness.close(); other.close() }
        harness.window.orderFrontRegardless()
        other.window.orderFrontRegardless()
        other.sidebar.inputTap = harness.tap // both windows' sidebars hear one tap, as in the app
        harness.deliver(try other.wheel(dx: -1, at: other.overList))
        #expect(harness.pages.isEmpty, "a notch in another window paged this window's spaces")
        #expect(other.pages == [1])
    }

    // MARK: Windowless synthesized scrolls

    @Test func aWindowlessScrollGoesToTheWindowItsQuartzFieldNames() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let elsewhere = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        elsewhere.isReleasedWhenClosed = false
        let screenPoint = NSPoint(x: 150, y: 260)
        func location(_ eventWindow: NSWindow?, _ quartz: Int?) -> NSPoint? {
            SidebarSwipeFeed.location(eventWindow: eventWindow, quartzWindowNumber: quartz, point: screenPoint, in: window)
        }
        #expect(location(nil, window.windowNumber) == NSPoint(x: 50, y: 60), "a windowless scroll's point is on the screen")
        #expect(location(nil, elsewhere.windowNumber) == nil, "a windowless scroll named another window")
        #expect(location(nil, nil) == nil, "a windowless scroll named no window")
        #expect(location(window, nil) == screenPoint, "a windowed scroll's point is already the window's")
        #expect(location(elsewhere, window.windowNumber) == nil, "an event's own window wins over its Quartz field")
    }
}
