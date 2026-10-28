import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar list's responsive scrolling (feature `responsiveScrolling`): with the feature
/// on, its scroll view opts in and a trackpad gesture reaches `super` only once ``ScrollAxisLatch`` rails it
/// vertical (or it ends too short to show an axis), then whole from its `mayBegin`, so a horizontal swipe (and its
/// momentum) stays the paging's and never becomes AppKit's to track. With it off, the list scrolls on the main
/// thread and routes each event as before. Swipes page on both.
///
/// Whether AppKit really scrolls the list off the main thread needs real input in a running app:
/// scripts/cmux-next/responsive-scroll-live.py (a 50 ms main stall during momentum).
@MainActor
@Suite(.serialized)
struct SidebarResponsiveScrollingTests {
    private static func sidebar(responsive: Bool = true) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let workspaces = (0..<60).map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace \($0)")) }
        let sidebar = SidebarView(model: SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces)]),
                                  design: DesignSettings(), responsiveScrolling: responsive)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    /// A trackpad scroll event (continuous pixel deltas) with its gesture and momentum phases.
    private static func event(dx: Int32 = 0, dy: Int32 = 0, phase: CGScrollPhase? = nil,
                              momentum: CGMomentumScrollPhase = .none) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test func theFeatureOptsTheListIntoResponsiveScrolling() throws {
        let sidebar = Self.sidebar()
        #expect(type(of: sidebar.scrollView).isCompatibleWithResponsiveScrolling)
        let document = try #require(sidebar.scrollView.documentView)
        let draw = #selector(NSView.draw(_:))
        // AppKit also needs the document compatible or not drawing (AppKit 10.9 notes, "Responsive Scrolling").
        #expect(type(of: document).isCompatibleWithResponsiveScrolling
            || type(of: document).instanceMethod(for: draw) == NSView.instanceMethod(for: draw))
        #expect(sidebar.scrollView.horizontalScrollElasticity == .none)
    }

    @Test func withTheFeatureOffTheListScrollsOnTheMainThreadAsBefore() {
        let sidebar = Self.sidebar(responsive: false)
        #expect(!type(of: sidebar.scrollView).isCompatibleWithResponsiveScrolling)
        #expect(sidebar.scrollView.horizontalScrollElasticity != .none)
    }

    @Test func aVerticalGestureReachesTheListWholeFromItsTouchDownOnceItShowsItsAxis() {
        var latch = ScrollAxisLatch<String>()
        #expect(latch.route("mayBegin", phase: nil, touchDown: true, deltaX: 0, deltaY: 0) == .hold, "fingers down: not AppKit's yet")
        #expect(latch.route("began", phase: .began, touchDown: false, deltaX: 0, deltaY: -1) == .hold)
        #expect(latch.route("changed1", phase: .changed, touchDown: false, deltaX: 1, deltaY: -3) == .list(["mayBegin", "began", "changed1"]),
                "4 pt mostly down: vertical, and the list gets the gesture from its start, in order")
        #expect(latch.route("changed2", phase: .changed, touchDown: false, deltaX: 30, deltaY: 0) == .list(["changed2"]),
                "railed: a sideways drift stays the list's")
        #expect(latch.route("ended", phase: .ended, touchDown: false, deltaX: 0, deltaY: 0) == .list(["ended"]))
        #expect(latch.route("momentum", phase: .momentum, touchDown: false, deltaX: 0, deltaY: -8) == .list(["momentum"]))
        #expect(latch.axis == .vertical)
    }

    @Test func aHorizontalGestureAndItsMomentumNeverReachTheList() {
        var latch = ScrollAxisLatch<String>()
        #expect(latch.route("mayBegin", phase: nil, touchDown: true, deltaX: 0, deltaY: 0) == .hold)
        #expect(latch.route("began", phase: .began, touchDown: false, deltaX: -3, deltaY: 0) == .hold)
        #expect(latch.route("changed1", phase: .changed, touchDown: false, deltaX: -3, deltaY: 1) == .horizontal, "its held start is dropped")
        #expect(latch.route("changed2", phase: .changed, touchDown: false, deltaX: 0, deltaY: -40) == .horizontal, "railed horizontal")
        #expect(latch.route("ended", phase: .ended, touchDown: false, deltaX: 0, deltaY: 0) == .horizontal)
        #expect(latch.route("momentum", phase: .momentum, touchDown: false, deltaX: -12, deltaY: 0) == .horizontal)
        // The next gesture decides again, with nothing of this one held.
        #expect(latch.route("next", phase: .began, touchDown: false, deltaX: 0, deltaY: 5) == .list(["next"]))
    }

    /// A swipe whose first points go diagonally (trackpad noise) is still a swipe: the latch waits until the
    /// gesture leans clearly one way, as the main-thread path's cumulative `ProfileSwipeTracker` does.
    @Test func aSwipeWithANoisyDiagonalStartStillRailsHorizontal() {
        var latch = ScrollAxisLatch<String>()
        #expect(latch.route("began", phase: .began, touchDown: false, deltaX: -2, deltaY: -2) == .hold)
        #expect(latch.route("changed1", phase: .changed, touchDown: false, deltaX: -3, deltaY: -1) == .hold,
                "5 pt by 3 pt leans neither way: still undecided")
        #expect(latch.route("changed2", phase: .changed, touchDown: false, deltaX: -10, deltaY: 0) == .horizontal,
                "15 pt by 3 pt: a swipe")
        #expect(latch.axis == .horizontal)
    }

    @Test func aGestureThatLeansNeitherWayIsTheListsAfterItsWindow() {
        var latch = ScrollAxisLatch<String>()
        #expect(latch.route("began", phase: .began, touchDown: false, deltaX: 4, deltaY: 3) == .hold, "not twice as wide as tall")
        #expect(latch.route("changed1", phase: .changed, touchDown: false, deltaX: 6, deltaY: 5) == .hold)
        #expect(latch.route("changed2", phase: .changed, touchDown: false, deltaX: 6, deltaY: 5) == .list(["began", "changed1", "changed2"]),
                "16 pt of a diagonal: the list scrolls it, as the main-thread path does")
    }

    @Test func aShortScrollAndATapStillReachTheList() {
        var short = ScrollAxisLatch<String>()
        #expect(short.route("mayBegin", phase: nil, touchDown: true, deltaX: 0, deltaY: 0) == .hold)
        #expect(short.route("began", phase: .began, touchDown: false, deltaX: 0, deltaY: -1) == .hold)
        #expect(short.route("changed", phase: .changed, touchDown: false, deltaX: 0, deltaY: -2) == .hold)
        #expect(short.route("ended", phase: .ended, touchDown: false, deltaX: 0, deltaY: 0) == .list(["mayBegin", "began", "changed", "ended"]),
                "3 pt never shows an axis: the gesture is the list's when it ends")
        #expect(short.axis == .vertical)
        var tap = ScrollAxisLatch<String>()
        #expect(tap.route("mayBegin", phase: nil, touchDown: true, deltaX: 0, deltaY: 0) == .hold)
        #expect(tap.route("cancelled", phase: .ended, touchDown: false, deltaX: 0, deltaY: 0) == .list(["mayBegin", "cancelled"]),
                "a tap shows and hides the overlay scroller as before")
        var stale = ScrollAxisLatch<String>()
        _ = stale.route("lost", phase: nil, touchDown: true, deltaX: 0, deltaY: 0)
        _ = stale.route("mayBegin", phase: nil, touchDown: true, deltaX: 0, deltaY: 0)
        #expect(stale.route("ended", phase: .ended, touchDown: false, deltaX: 0, deltaY: 0) == .list(["mayBegin", "ended"]),
                "a new touch-down drops a gesture whose end never came")
        var phaseless = ScrollAxisLatch<String>()
        #expect(phaseless.route("free", phase: nil, touchDown: false, deltaX: 0, deltaY: -2) == .list(["free"]), "outside a gesture: the list's")
    }

    @Test func aShortVerticalGestureStillMovesTheClip() throws {
        let list = Self.sidebar().scrollView
        // Mid-list, so a scroll either way moves the clip rather than bounce at an edge.
        list.contentView.scroll(to: NSPoint(x: 0, y: 200))
        list.reflectScrolledClipView(list.contentView)
        let origin = list.contentView.bounds.origin
        try #require(origin.y == 200, "60 rows overflow a 400 pt list")
        list.scrollWheel(with: try Self.event(phase: .mayBegin))
        list.scrollWheel(with: try Self.event(dy: -1, phase: .began))
        list.scrollWheel(with: try Self.event(dy: -2, phase: .changed))
        #expect(list.contentView.bounds.origin == origin, "held until the gesture shows its axis or ends")
        list.scrollWheel(with: try Self.event(phase: .ended))
        #expect(list.contentView.bounds.origin != origin, "the held 3 pt reach the list when the gesture ends")
    }

    /// One scroll as the app delivers it: the input tap feeds the paging (`SidebarSwipeFeed`), then AppKit
    /// dispatches it to the list's `scrollWheel(with:)`.
    private static func deliver(_ event: NSEvent, to list: SidebarScrollView) {
        list.swipes.receive(event) { true }
        list.scrollWheel(with: event)
    }

    @Test(arguments: [true, false])
    func aSwipeOverTheListPagesOneToOneAndKeepsTheClipStill(responsive: Bool) throws {
        let list = Self.sidebar(responsive: responsive).scrollView
        let origin = list.contentView.bounds.origin
        var reports: [(ProfileSwipeTracker.Phase, CGFloat)] = []
        list.onHorizontalScroll = { phase, dx, _ in reports.append((phase, dx)) }
        Self.deliver(try Self.event(phase: .mayBegin), to: list)
        Self.deliver(try Self.event(dx: -3, phase: .began), to: list)
        #expect(reports.isEmpty, "held until the gesture shows its axis")
        Self.deliver(try Self.event(dx: -6, phase: .changed), to: list)
        Self.deliver(try Self.event(dx: -9, phase: .changed), to: list)
        Self.deliver(try Self.event(phase: .ended), to: list)
        Self.deliver(try Self.event(dx: -10, momentum: .begin), to: list)
        Self.deliver(try Self.event(dx: -4, momentum: .continuous), to: list)
        #expect(reports.map(\.0) == [.began, .changed, .ended])
        #expect(reports.map(\.1) == [-6, -9, 0])
        #expect(list.contentView.bounds.origin == origin)
    }

    @Test(arguments: [true, false])
    func aLongSwipeSwitchesOnceWithoutTheOneToOneHandler(responsive: Bool) throws {
        let list = Self.sidebar(responsive: responsive).scrollView
        list.onHorizontalScroll = nil
        var steps: [Int] = []
        list.onHorizontalSwipe = { steps.append($0) }
        Self.deliver(try Self.event(dx: -10, phase: .began), to: list)
        for _ in 0..<6 { Self.deliver(try Self.event(dx: -20, phase: .changed), to: list) }
        Self.deliver(try Self.event(phase: .ended), to: list)
        #expect(steps == [1], "one switch per gesture, to the next profile for a leftward swipe")
    }

    /// The finding's case over the real list: (-2, -2), (-3, -1), then 100 pt sideways still switches once.
    @Test(arguments: [true, false])
    func aSwipeWithANoisyDiagonalStartSwitchesOverTheList(responsive: Bool) throws {
        let list = Self.sidebar(responsive: responsive).scrollView
        list.onHorizontalScroll = nil
        var steps: [Int] = []
        list.onHorizontalSwipe = { steps.append($0) }
        Self.deliver(try Self.event(dx: -2, dy: -2, phase: .began), to: list)
        Self.deliver(try Self.event(dx: -3, dy: -1, phase: .changed), to: list)
        for _ in 0..<5 { Self.deliver(try Self.event(dx: -20, phase: .changed), to: list) }
        Self.deliver(try Self.event(phase: .ended), to: list)
        #expect(steps == [1])
    }
}
