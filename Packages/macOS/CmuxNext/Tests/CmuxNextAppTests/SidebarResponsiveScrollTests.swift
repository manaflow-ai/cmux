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

    /// A list document as the sidebar's: flipped, 4,000 points of rows in a 400 point clip.
    private final class Rows: NSView { override var isFlipped: Bool { true } }

    private func list() -> SidebarScrollView {
        let scroll = SidebarScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        scroll.documentView = Rows(frame: NSRect(x: 0, y: 0, width: 260, height: 4_000))
        return scroll
    }

    @Test func theSidebarListTakesResponsiveScrolling() {
        #expect(SidebarScrollView.isCompatibleWithResponsiveScrolling)
    }

    /// A swipe whose first event carries no movement is not handed to AppKit (which would track the
    /// rest of the gesture itself): it pages the spaces from its first sideways change.
    @Test func aSidewaysSwipeThatStartsStillStillPagesTheSpaces() {
        let scroll = list()
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
        let scroll = list()
        var phases: [ProfileSwipeTracker.Phase] = []
        scroll.onHorizontalScroll = { phase, _, _ in phases.append(phase) }
        scroll.scrollWheel(with: event(dx: 2, dy: 3, phase: .began))
        for _ in 0..<3 { scroll.scrollWheel(with: event(dx: -20, dy: 0, phase: .changed)) }
        scroll.scrollWheel(with: event(dx: 0, dy: 0, phase: .ended))
        #expect(phases == [.began, .changed, .changed, .ended])
    }

    /// A swipe that pages keeps the gesture to its end, however its later events drift: AppKit,
    /// once it had the gesture, would keep its end from the pager and leave the spaces half moved
    /// (review of #34648).
    @Test func aPagingSwipeThatDriftsDownStillEndsItsPage() {
        let scroll = list()
        var phases: [ProfileSwipeTracker.Phase] = []
        scroll.onHorizontalScroll = { phase, _, _ in phases.append(phase) }
        let origin = scroll.contentView.bounds.origin
        scroll.scrollWheel(with: event(dx: -20, dy: 0, phase: .began))
        for _ in 0..<3 { scroll.scrollWheel(with: event(dx: 0, dy: -20, phase: .changed)) }
        scroll.scrollWheel(with: event(dx: 0, dy: 0, phase: .ended))
        #expect(phases.first == .began && phases.last == .ended, "\(phases)")
        #expect(scroll.contentView.bounds.origin == origin, "a paging swipe never scrolls the list")
    }

    /// Movement held back while a gesture had no direction is scrolled, not lost: once it turns
    /// out vertical, and when it ends without a direction (review of #34648).
    @Test func heldBackMovementStillScrollsTheList() {
        let short = list()
        short.scrollWheel(with: event(dx: 0, dy: -2, phase: .began))
        short.scrollWheel(with: event(dx: 0, dy: 0, phase: .ended))
        #expect(short.contentView.bounds.minY == 2, "a 2 point gesture scrolled \(short.contentView.bounds.minY)")

        let slow = list()
        slow.scrollWheel(with: event(dx: 0, dy: -2, phase: .began))
        slow.scrollWheel(with: event(dx: 0, dy: -2, phase: .changed))
        #expect(slow.contentView.bounds.minY == 0, "undecided: nothing scrolled yet")
        slow.scrollWheel(with: event(dx: 0, dy: -2, phase: .changed)) // 6 points: vertical
        #expect(slow.contentView.bounds.minY >= 4, "the 4 held points scrolled; got \(slow.contentView.bounds.minY)")
    }

    /// At the bottom of a list with a bottom inset (the Needs You tray's room), a short gesture's
    /// held-back movement keeps the inset: the last rows stay above the tray (review of #34648).
    @Test func heldBackMovementKeepsTheBottomInset() {
        let scroll = list()
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 120, right: 0)
        let bottom = 4_000 - 400 + 120.0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(abs(scroll.contentView.bounds.minY - bottom) < 0.5, "the inset bottom is reachable")
        scroll.scrollWheel(with: event(dx: 0, dy: 2, phase: .began))
        scroll.scrollWheel(with: event(dx: 0, dy: 0, phase: .ended))
        #expect(abs(scroll.contentView.bounds.minY - (bottom - 2)) < 0.5, "scrolled 2 up from the inset bottom; at \(scroll.contentView.bounds.minY)")
    }

    /// The rows AppKit prepared for a scroll near the top realize nothing after a jump to the
    /// bottom (a reveal): the list holds about the rows it shows, never every row between the two
    /// places (review of #34648).
    @Test func aFarJumpRealizesOnlyTheRowsAroundItsViewport() {
        let bench = SidebarScrollBench(count: 500)
        defer { bench.close() }
        bench.list.prepareContent(in: bench.clip.bounds.insetBy(dx: 0, dy: -200))
        _ = bench.frame(to: bench.maxY)
        let realized = bench.list.rowViews.count, visible = bench.visibleRows
        #expect(realized <= visible * 2, "a far jump realized \(realized) rows for \(visible) visible")
    }

    /// What the list tells AppKit is prepared always has row views: after AppKit asks for a wide
    /// rect, after a scroll down and after the scroll back, with no new ask between (review of #34648).
    @Test func everyPreparedRowHasAView() {
        let bench = SidebarScrollBench(count: 500)
        defer { bench.close() }
        func check(_ when: String) {
            let prepared = bench.list.preparedContentRect
            let missing = bench.list.displayed.rows.filter { prepared.intersects(bench.list.frame(for: $0)) && bench.list.rowViews[$0.key] == nil }
            #expect(missing.isEmpty, "\(when): \(missing.count) prepared rows have no view")
        }
        bench.list.prepareContent(in: bench.clip.bounds.insetBy(dx: 0, dy: -1_500))
        check("after a wide ask")
        _ = bench.frame(to: 1_200)
        check("after a scroll down")
        _ = bench.frame(to: 400)
        check("after the scroll back")
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
