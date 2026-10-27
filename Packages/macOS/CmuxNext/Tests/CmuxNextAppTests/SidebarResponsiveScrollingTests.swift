import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar list keeps AppKit's responsive scrolling (p03-rendering-110): its scroll view opts back in,
/// and a trackpad gesture reaches `super` only once ``ScrollAxisLatch`` rails it vertical, so a horizontal
/// swipe (and its momentum) stays the paging's and never becomes AppKit's to track.
@MainActor
@Suite(.serialized)
struct SidebarResponsiveScrollingTests {
    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let workspaces = (0..<60).map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace \($0)")) }
        let sidebar = SidebarView(model: SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces)]),
                                  design: DesignSettings())
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

    @Test func theListOptsIntoResponsiveScrolling() throws {
        let sidebar = Self.sidebar()
        #expect(SidebarScrollView.isCompatibleWithResponsiveScrolling)
        let document = try #require(sidebar.scrollView.documentView)
        let draw = #selector(NSView.draw(_:))
        // AppKit also needs the document compatible or not drawing (AppKit 10.9 notes, "Responsive Scrolling").
        #expect(type(of: document).isCompatibleWithResponsiveScrolling
            || type(of: document).instanceMethod(for: draw) == NSView.instanceMethod(for: draw))
        #expect(sidebar.scrollView.horizontalScrollElasticity == .none)
    }

    @Test func aVerticalGestureIsHeldUntilItsFirstPointsThenTheListsWithItsMomentum() {
        var latch = ScrollAxisLatch()
        #expect(latch.route(phase: nil, touchDown: true, deltaX: 0, deltaY: 0) == .hold, "fingers down: not AppKit's yet")
        #expect(latch.route(phase: .began, touchDown: false, deltaX: 0, deltaY: -1) == .hold)
        #expect(latch.route(phase: .changed, touchDown: false, deltaX: 1, deltaY: -3) == .list, "4 pt mostly down: vertical")
        #expect(latch.route(phase: .changed, touchDown: false, deltaX: 30, deltaY: 0) == .list, "railed: a sideways drift stays the list's")
        #expect(latch.route(phase: .ended, touchDown: false, deltaX: 0, deltaY: 0) == .list)
        #expect(latch.route(phase: .momentum, touchDown: false, deltaX: 0, deltaY: -8) == .list)
        #expect(latch.axis == .vertical)
    }

    @Test func aHorizontalGestureAndItsMomentumNeverReachTheList() {
        var latch = ScrollAxisLatch()
        #expect(latch.route(phase: .began, touchDown: false, deltaX: -3, deltaY: 0) == .hold)
        #expect(latch.route(phase: .changed, touchDown: false, deltaX: -3, deltaY: 1) == .horizontal)
        #expect(latch.route(phase: .changed, touchDown: false, deltaX: 0, deltaY: -40) == .horizontal, "railed horizontal")
        #expect(latch.route(phase: .ended, touchDown: false, deltaX: 0, deltaY: 0) == .horizontal)
        #expect(latch.route(phase: .momentum, touchDown: false, deltaX: -12, deltaY: 0) == .horizontal)
        // The next gesture decides again.
        #expect(latch.route(phase: .began, touchDown: false, deltaX: 0, deltaY: 5) == .list)
    }

    @Test func aDiagonalGestureIsTheListsAndATapScrollsNothing() {
        var diagonal = ScrollAxisLatch()
        #expect(diagonal.route(phase: .began, touchDown: false, deltaX: 4, deltaY: 3) == .list, "not twice as wide as tall")
        var tap = ScrollAxisLatch()
        #expect(tap.route(phase: nil, touchDown: true, deltaX: 0, deltaY: 0) == .hold)
        #expect(tap.route(phase: .began, touchDown: false, deltaX: 1, deltaY: 1) == .hold)
        #expect(tap.route(phase: .ended, touchDown: false, deltaX: 0, deltaY: 0) == .hold)
        #expect(tap.axis == .undecided)
        var phaseless = ScrollAxisLatch()
        #expect(phaseless.route(phase: nil, touchDown: false, deltaX: 0, deltaY: -2) == .list, "outside a gesture: the list's")
    }

    @Test func aSwipeOverTheListPagesOneToOneAndKeepsTheClipStill() throws {
        let sidebar = Self.sidebar()
        let list = sidebar.scrollView
        let origin = list.contentView.bounds.origin
        var reports: [(ProfileSwipeTracker.Phase, CGFloat)] = []
        list.onHorizontalScroll = { phase, dx, _ in reports.append((phase, dx)) }
        list.scrollWheel(with: try Self.event(phase: .mayBegin))
        list.scrollWheel(with: try Self.event(dx: -3, phase: .began))
        #expect(reports.isEmpty, "held until the gesture shows its axis")
        list.scrollWheel(with: try Self.event(dx: -6, phase: .changed))
        list.scrollWheel(with: try Self.event(dx: -9, phase: .changed))
        list.scrollWheel(with: try Self.event(phase: .ended))
        list.scrollWheel(with: try Self.event(dx: -10, momentum: .begin))
        list.scrollWheel(with: try Self.event(dx: -4, momentum: .continuous))
        #expect(reports.map(\.0) == [.began, .changed, .ended])
        #expect(reports.map(\.1) == [-6, -9, 0])
        #expect(list.contentView.bounds.origin == origin)
    }

    @Test func aLongSwipeSwitchesOnceWithoutTheOneToOneHandler() throws {
        let list = Self.sidebar().scrollView
        list.onHorizontalScroll = nil
        var steps: [Int] = []
        list.onHorizontalSwipe = { steps.append($0) }
        list.scrollWheel(with: try Self.event(dx: -10, phase: .began))
        for _ in 0..<6 { list.scrollWheel(with: try Self.event(dx: -20, phase: .changed)) }
        list.scrollWheel(with: try Self.event(phase: .ended))
        #expect(steps == [1], "one switch per gesture, to the next profile for a leftward swipe")
    }
}
