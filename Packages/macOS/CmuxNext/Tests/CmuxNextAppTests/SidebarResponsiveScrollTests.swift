import AppKit
@testable import CmuxNextSidebar
import CoreGraphics
import Testing

/// Leo, ask-757eeb7f80: "scrolling thru sidebar sessions in claude doesn't lag / in cmux-next it
/// does". The list's scroll view overrides `scrollWheel(with:)` (sideways swipes page the spaces),
/// which opts it out of AppKit's responsive scrolling unless it says it is compatible: every scroll
/// frame then waited on the main thread. It says so now, and a sideways swipe still pages: a
/// gesture is held from AppKit until it shows its direction.
@MainActor
struct SidebarResponsiveScrollTests {
    private func event(dx: Int32, dy: Int32, phase: CGScrollPhase) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        return NSEvent(cgEvent: cg)!
    }

    @Test func theSidebarListTakesResponsiveScrolling() {
        #expect(SidebarScrollView.isCompatibleWithResponsiveScrolling)
    }

    /// A swipe whose first event carries no movement is not handed to AppKit (which would track the
    /// rest of the gesture itself): it pages the spaces from its first sideways change.
    @Test func aSidewaysSwipeThatStartsStillStillPagesTheSpaces() {
        let scroll = SidebarScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 4_000))
        var phases: [ProfileSwipeTracker.Phase] = []
        scroll.onHorizontalScroll = { phase, _, _ in phases.append(phase) }
        let origin = scroll.contentView.bounds.origin
        scroll.scrollWheel(with: event(dx: 0, dy: 0, phase: .began))
        for _ in 0..<3 { scroll.scrollWheel(with: event(dx: -20, dy: 0, phase: .changed)) }
        scroll.scrollWheel(with: event(dx: 0, dy: 0, phase: .ended))
        #expect(phases == [.began, .changed, .changed, .ended])
        #expect(scroll.contentView.bounds.origin == origin, "a sideways swipe never scrolls the list")
    }

    /// A first sample that leans a little downward (2, 3) is not a direction yet: the swipe that
    /// follows still pages (review of #34648).
    @Test func aSidewaysSwipeThatStartsALittleDownStillPagesTheSpaces() {
        let scroll = SidebarScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 4_000))
        var phases: [ProfileSwipeTracker.Phase] = []
        scroll.onHorizontalScroll = { phase, _, _ in phases.append(phase) }
        scroll.scrollWheel(with: event(dx: 2, dy: 3, phase: .began))
        for _ in 0..<3 { scroll.scrollWheel(with: event(dx: -20, dy: 0, phase: .changed)) }
        scroll.scrollWheel(with: event(dx: 0, dy: 0, phase: .ended))
        #expect(phases == [.began, .changed, .changed, .ended])
    }

    @Test func aGestureShowsOneDirectionOnceItMoves() {
        var sideways = ProfileSwipeTracker()
        _ = sideways.feed(deltaX: 0, deltaY: 0, phase: .began)
        #expect(!sideways.isHorizontal && !sideways.isVertical, "no movement yet: undecided")
        _ = sideways.feed(deltaX: -10, deltaY: 1, phase: .changed)
        #expect(sideways.isHorizontal && !sideways.isVertical)

        var down = ProfileSwipeTracker()
        _ = down.feed(deltaX: 2, deltaY: -6, phase: .began)
        #expect(down.isVertical && !down.isHorizontal)

        // Diagonal, not mostly sideways: it scrolls, as it did.
        var diagonal = ProfileSwipeTracker()
        _ = diagonal.feed(deltaX: 9, deltaY: 5, phase: .began)
        #expect(diagonal.isVertical && !diagonal.isHorizontal)
    }
}
