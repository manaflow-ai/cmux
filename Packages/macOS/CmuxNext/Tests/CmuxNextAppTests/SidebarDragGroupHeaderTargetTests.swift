import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-05: "in terms of just the proper, you know, dragging correctness kind of things, I feel like there's
/// stuff we can do there" (his recording: rows jumping while a workspace was dragged over a group's header). Two
/// causes, both on the sidebar document's drag (the app's path):
/// - An open group's header bottom quarter meant "after the whole group": the gap jumped from above the first member
///   to below the last one, and every member sprang up a slot. It sits right over the first member, so it means
///   before that member, first in the group.
/// - An into-group target closed the gap for one move: the rows sprang up, the same still pointer then read one row
///   lower, and the gap opened again. Over the header's middle the list keeps the last gap, as over a row's middle.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarDragGroupHeaderTargetTests {
    typealias Slot = SidebarDragGeometry.Slot

    static func rect(_ y: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 200, height: 20) }

    /// Loose `w1` 0..20; open group `g` 20..40 with `m1` 40..60 and `m2` 60..80; loose `w2` 80..100.
    static let slots: [Slot] = [
        Slot(key: "w1", item: "w1", section: "s", frame: rect(0), kind: .row),
        Slot(key: "g", item: "g", section: "s", frame: rect(20), kind: .group),
        Slot(key: "m1", item: "m1", section: "s", parent: "g", frame: rect(40), kind: .row),
        Slot(key: "m2", item: "m2", section: "s", parent: "g", frame: rect(60), kind: .row),
        Slot(key: "w2", item: "w2", section: "s", frame: rect(80), kind: .row),
    ]

    @Test func anOpenHeadersBottomBandDropsBeforeItsFirstMember() {
        let geometry = SidebarDragGeometry(slots: Self.slots, acceptance: [:])
        // 38: the header's bottom quarter, right over m1.
        #expect(geometry.hit(CGPoint(x: 100, y: 38))?.target == SidebarDocTarget(section: "s", parent: "g", before: "m1"))
        // The header's middle still drops into the group, its top quarter before it.
        #expect(geometry.hit(CGPoint(x: 100, y: 30))?.target == SidebarDocTarget(section: "s", parent: "g"))
        #expect(geometry.hit(CGPoint(x: 100, y: 22))?.target == SidebarDocTarget(section: "s", before: "g"))
    }

    @Test func aClosedHeadersBottomBandStillDropsAfterTheGroup() {
        let closed = Self.slots.filter { $0.parent == nil }.map { slot -> Slot in
            var slot = slot
            if slot.key == "w2" { slot.frame = Self.rect(40) }
            return slot
        }
        let geometry = SidebarDragGeometry(slots: closed, acceptance: [:])
        #expect(geometry.hit(CGPoint(x: 100, y: 38))?.target == SidebarDocTarget(section: "s", after: "g"))
    }

    /// A collapsed group that keeps its active member shown is still closed: its header's bottom quarter drops after
    /// the group, not into it before the kept member (review of 121167f).
    @Test func aCollapsedHeaderWithAKeptMemberStillDropsAfterTheGroup() {
        let kept = Self.slots.filter { $0.key != "m2" }.map { slot -> Slot in
            var slot = slot
            if slot.key == "g" { slot.collapsed = true }
            if slot.key == "w2" { slot.frame = Self.rect(60) }
            return slot
        }
        let geometry = SidebarDragGeometry(slots: kept, acceptance: [:])
        #expect(geometry.hit(CGPoint(x: 100, y: 38))?.target == SidebarDocTarget(section: "s", after: "g"))
    }

    /// The group's first member lifted and nudged up: it stays first in its group, and the other member stays put.
    @Test func aFirstMemberNudgedUpStaysFirstInItsGroup() throws {
        let drops = SidebarRowEdgeReorderDocDragTests.Drops()
        let (list, window) = SidebarRowEdgeReorderDocDragTests.list(drops)
        defer { window.close() }
        let m2Before = try #require(list.rowViews[.workspace(WorkspaceID("m2"))]).frame
        let m1 = try SidebarRowEdgeReorderDocDragTests.row(list, "m1")
        let start = NSPoint(x: 80, y: m1.y + m1.height / 2)
        list.press = SidebarPress(key: m1.key, point: start)
        list.beginDrag(try #require(list.press))
        let drag = try #require(list.drag, "m1 did not lift")
        for dy in [1, 2, 3] as [CGFloat] {
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: start.y - dy), to: nil))
            #expect(drag.target == .position(DropPosition(section: m1.section, group: GroupID("g"), index: 0)),
                    "\(dy) pt up: \(String(describing: drag.target))")
            #expect(list.rowViews[.workspace(WorkspaceID("m2"))]?.frame == m2Before, "\(dy) pt up: m2 moved")
        }
        list.cancelDrag()
        if let landing = list.landing { list.finishLand(landing, then: nil) }
    }

    /// w3 dragged down onto the group header's middle (into the group): the header and its members stay where the last
    /// gap put them, and a still pointer there keeps that target.
    @Test func aHeldDragOverAHeadersMiddleKeepsTheRowsWhereTheyAre() throws {
        let drops = SidebarRowEdgeReorderDocDragTests.Drops()
        let (list, window) = SidebarRowEdgeReorderDocDragTests.list(drops)
        defer { window.close() }
        let w3 = try SidebarRowEdgeReorderDocDragTests.row(list, "w3")
        let start = NSPoint(x: 80, y: w3.y + w3.height / 2)
        list.press = SidebarPress(key: w3.key, point: start)
        list.beginDrag(try #require(list.press))
        let drag = try #require(list.drag, "w3 did not lift")
        let keys: [SidebarRowKey] = [.group(GroupID("g")), .workspace(WorkspaceID("m1")), .workspace(WorkspaceID("m2"))]
        func frames() -> [NSRect?] { keys.map { list.rowViews[$0]?.frame } }
        var before = frames()
        var y = start.y
        while y < start.y + 80, drag.target != .intoGroup(GroupID("g")) {
            before = frames()
            y += 1
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
        }
        try #require(drag.target == .intoGroup(GroupID("g")), "the drag never went into the group: \(String(describing: drag.target))")
        #expect(frames() == before, "over the header's middle the rows moved: \(before) → \(frames())")
        for _ in 0..<3 {
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
            #expect(drag.target == .intoGroup(GroupID("g")), "a still pointer left the group: \(String(describing: drag.target))")
            #expect(frames() == before, "a still pointer moved the rows: \(frames())")
        }
        list.cancelDrag()
        if let landing = list.landing { list.finishLand(landing, then: nil) }
    }

    /// w3 dragged down through the group a point at a time: each place the drop offers comes once, in order; none
    /// comes back after another (no gap closing and opening again under the pointer).
    @Test func aDragDownThroughAGroupNeverReturnsToAPlaceItLeft() throws {
        let drops = SidebarRowEdgeReorderDocDragTests.Drops()
        let (list, window) = SidebarRowEdgeReorderDocDragTests.list(drops)
        defer { window.close() }
        let w3 = try SidebarRowEdgeReorderDocDragTests.row(list, "w3")
        let m2 = try SidebarRowEdgeReorderDocDragTests.row(list, "m2")
        let start = NSPoint(x: 80, y: w3.y + w3.height / 2)
        list.press = SidebarPress(key: w3.key, point: start)
        list.beginDrag(try #require(list.press))
        let drag = try #require(list.drag, "w3 did not lift")
        var seen: [String] = []
        var y = start.y
        while y < m2.maxY + 4 {
            y += 1
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
            let now = String(describing: drag.target)
            if seen.last != now { seen.append(now) }
        }
        let repeats = seen.enumerated().filter { at, target in seen[..<at].contains(target) }.map(\.element)
        #expect(repeats.isEmpty, "the drop came back to \(repeats) after leaving it: \(seen.joined(separator: " → "))")
        list.cancelDrag()
        if let landing = list.landing { list.finishLand(landing, then: nil) }
    }
}
