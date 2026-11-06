import CoreGraphics
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-20: a dragged workspace (or listed item) reorders as soon
/// as its top edge goes above the middle of the row above it, and as soon as
/// its bottom edge goes below the middle of the row below it. A drag that
/// turns back must pass the middle by a margin before it swaps back.
@Suite struct SidebarDragGeometryEdgeReorderTests {
    typealias Slot = SidebarDragGeometry.Slot

    /// The list without the dragged card: section header 0..20; loose `a`
    /// 20..40; tall loose `b` 40..80; loose `c` 80..100; group `g` 100..120
    /// with members `m1` 120..140 and `m2` 140..160.
    static let geometry = SidebarDragGeometry(slots: [
        Slot(key: "s", item: nil, section: "s", frame: rect(0, 20), kind: .section),
        Slot(key: "a", item: "a", section: "s", frame: rect(20, 20), kind: .row),
        Slot(key: "b", item: "b", section: "s", frame: rect(40, 40), kind: .row),
        Slot(key: "c", item: "c", section: "s", frame: rect(80, 20), kind: .row),
        Slot(key: "g", item: "g", section: "s", frame: rect(100, 20), kind: .group),
        Slot(key: "m1", item: "m1", section: "s", parent: "g", frame: rect(120, 20), kind: .row),
        Slot(key: "m2", item: "m2", section: "s", parent: "g", frame: rect(140, 20), kind: .row),
    ], acceptance: [:])

    static func rect(_ y: CGFloat, _ height: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 200, height: height) }

    /// The drop for a card `height` tall with its top at `top`, the gap open at `gapY` (as tall as the card).
    static func target(top: CGFloat, height: CGFloat = 20, up: Bool, gapY: CGFloat, current: SidebarDocTarget? = nil,
                       reversing: Bool = false) -> SidebarDocTarget?? {
        guard let y = geometry.edgeY(top: top, bottom: top + height, x: 100, movingUp: up, gapY: gapY, gapHeight: height,
                                     current: current, reversing: reversing) else { return .none }
        return .some(geometry.hit(CGPoint(x: 100, y: y))?.target)
    }

    static func t(before: String? = nil, after: String? = nil, parent: String? = nil) -> SidebarDocTarget {
        SidebarDocTarget(section: "s", parent: parent, before: before, after: after)
    }

    /// A card at rest in its gap stays there, whichever way it last moved.
    @Test func aCardAtRestStays() {
        #expect(Self.target(top: 80, up: true, gapY: 80) == .some(Self.t(before: "c")))
        #expect(Self.target(top: 80, up: false, gapY: 80) == .some(Self.t(before: "c")))
    }

    /// Up past a tall row: the top edge 1 pt above the row's middle swaps (the card's centre is still in its lower half).
    @Test func upSwapsWhenTheTopEdgePassesTheMiddleAbove() {
        #expect(Self.target(top: 61, up: true, gapY: 80) == .some(Self.t(after: "b")))
        #expect(Self.target(top: 59, up: true, gapY: 80) == .some(Self.t(before: "b")))
    }

    /// Down past a tall row (drawn at 60..100 below the gap at 40): the bottom edge 1 pt below its middle swaps.
    @Test func downSwapsWhenTheBottomEdgePassesTheMiddleBelow() {
        #expect(Self.target(top: 59, up: false, gapY: 40) == .some(Self.t(before: "b")))
        #expect(Self.target(top: 61, up: false, gapY: 40) == .some(Self.t(after: "b")))
    }

    /// A tall card (a workspace with a status block, 60 pt) swaps with a short row as soon as its bottom passes that
    /// row's middle, while its centre is still far above the row.
    @Test func aTallCardMovesDownByItsBottomEdge() {
        // The gap at 80 (between b and c): c is drawn at 140..160, its middle at 150.
        #expect(Self.target(top: 89, height: 60, up: false, gapY: 80) == .some(Self.t(before: "c")))
        #expect(Self.target(top: 91, height: 60, up: false, gapY: 80) == .some(Self.t(after: "c")))
    }

    /// A tall card moves up past a short row as soon as its top passes that row's middle.
    @Test func aTallCardMovesUpByItsTopEdge() {
        // The gap at 40 (between a and b): a's middle is at 30.
        #expect(Self.target(top: 31, height: 60, up: true, gapY: 40) == .some(Self.t(after: "a")))
        #expect(Self.target(top: 29, height: 60, up: true, gapY: 40) == .some(Self.t(before: "a")))
    }

    /// Inside a group: a member moves above the member over it by the same rule, and stays in the group.
    @Test func aMemberMovesUpInsideItsGroup() {
        // The gap at 140 (between m1 and m2): m1's middle is at 130.
        #expect(Self.target(top: 131, up: true, gapY: 140) == .some(Self.t(after: "m1", parent: "g")))
        #expect(Self.target(top: 129, up: true, gapY: 140) == .some(Self.t(before: "m1", parent: "g")))
    }

    /// Once swapped up past `b`, turning back down swaps back only when the bottom edge passes `b`'s middle (now
    /// drawn at 80, below the gap at 40) by the margin: no flicker at the threshold.
    @Test func turningBackNeedsTheMargin() {
        let swapped = Self.t(before: "b")
        let margin = SidebarDragGeometry.hysteresis(for: 40)
        // Just past the middle: held.
        #expect(Self.target(top: 61, up: false, gapY: 40, current: swapped, reversing: true) == .none)
        // Past the middle by the margin: back after b.
        #expect(Self.target(top: 61 + margin, up: false, gapY: 40, current: swapped, reversing: true) == .some(Self.t(after: "b")))
        // The same point, still moving the way it swapped: no margin.
        #expect(Self.target(top: 61, up: false, gapY: 40, current: swapped, reversing: false) == .some(Self.t(after: "b")))
    }
}
