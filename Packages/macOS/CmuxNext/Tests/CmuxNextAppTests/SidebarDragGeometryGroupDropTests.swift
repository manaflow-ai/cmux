import CoreGraphics
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-18 (scrawl-1792382497882-1673e-10): dragging a whole
/// group "can't drop it in between every single group properly". On the
/// sidebar document path a dragged group was refused over every member row
/// of the other groups (groups do not nest) and over each header's middle
/// band, so a gap opened only on the thin top and bottom bands of a header.
/// A drop that cannot go into a group now goes before or after that whole
/// group, by the half of its block the probe is in.
@Suite struct SidebarDragGeometryGroupDropTests {
    typealias Slot = SidebarDragGeometry.Slot

    /// Home's section header 0..20; loose `w1` 20..40; group `g1` 40..60 with
    /// `m1` 60..80 and `m2` 80..100; group `g2` 100..120 with `m3` 120..140.
    static let slots: [Slot] = [
        Slot(key: "s", item: nil, section: "s", frame: rect(0), kind: .section),
        Slot(key: "w1", item: "w1", section: "s", frame: rect(20), kind: .row),
        Slot(key: "g1", item: "g1", section: "s", frame: rect(40), kind: .group),
        Slot(key: "m1", item: "m1", section: "s", parent: "g1", frame: rect(60), kind: .row),
        Slot(key: "m2", item: "m2", section: "s", parent: "g1", frame: rect(80), kind: .row),
        Slot(key: "g2", item: "g2", section: "s", frame: rect(100), kind: .group),
        Slot(key: "m3", item: "m3", section: "s", parent: "g2", frame: rect(120), kind: .row),
    ]

    static func rect(_ y: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 200, height: 20) }

    /// What `drag_begin` gives for a dragged group: no member row of a group and no group header's middle takes it.
    static let groupDrag: [String: SidebarDocAcceptance] = [
        "s": SidebarDocAcceptance(before: false, into: true, after: false),
        "w1": SidebarDocAcceptance(before: true, into: false, after: true),
        "g1": SidebarDocAcceptance(before: true, into: false, after: true, refusal: nil),
        "m1": SidebarDocAcceptance(before: false, into: false, after: false, refusal: "nesting"),
        "m2": SidebarDocAcceptance(before: false, into: false, after: false, refusal: "nesting"),
        "g2": SidebarDocAcceptance(before: true, into: false, after: true, refusal: nil),
        "m3": SidebarDocAcceptance(before: false, into: false, after: false, refusal: "nesting"),
    ]

    func probe(_ y: CGFloat, _ acceptance: [String: SidebarDocAcceptance] = groupDrag) -> SidebarDragGeometry.Hit? {
        SidebarDragGeometry(slots: Self.slots, acceptance: acceptance).hit(CGPoint(x: 100, y: y))
    }

    @Test(arguments: [
        // A member row in the upper half of g1's block (40..100): before g1.
        (CGFloat(65), SidebarDocTarget(section: "s", before: "g1")),
        // The lower half: after g1, between g1 and g2.
        (CGFloat(85), SidebarDocTarget(section: "s", after: "g1")),
        // g1's header middle and its bottom band: before g1 (the header is the block's top).
        (CGFloat(50), SidebarDocTarget(section: "s", before: "g1")),
        (CGFloat(58), SidebarDocTarget(section: "s", before: "g1")),
        // g1's header top band: before g1, as before.
        (CGFloat(42), SidebarDocTarget(section: "s", before: "g1")),
        // The last group's last member: after g2, the list's end.
        (CGFloat(135), SidebarDocTarget(section: "s", after: "g2")),
        // g2's header: before g2, between g1 and g2.
        (CGFloat(110), SidebarDocTarget(section: "s", before: "g2")),
        // A loose row keeps its halves.
        (CGFloat(25), SidebarDocTarget(section: "s", before: "w1")),
        (CGFloat(35), SidebarDocTarget(section: "s", after: "w1")),
        // The section header: first in the section, the top of the list under Home.
        (CGFloat(5), SidebarDocTarget(section: "s", index: 0)),
    ])
    func draggedGroupDropsBetweenGroups(y: CGFloat, expected: SidebarDocTarget) throws {
        let hit = try #require(probe(y))
        #expect(hit.target == expected)
        #expect(hit.refusal == nil)
    }

    @Test func everyGapBetweenGroupsIsReachable() {
        // Sweep the whole list a point at a time: every y takes a drop, and each gap of the list is reached.
        let targets = stride(from: CGFloat(0), to: 140, by: 1).compactMap { probe($0)?.target }
        #expect(targets.count == 140)
        let reached = Set(targets)
        #expect(reached.contains(SidebarDocTarget(section: "s", index: 0)))
        #expect(reached.contains(SidebarDocTarget(section: "s", after: "w1")))
        #expect(reached.contains(SidebarDocTarget(section: "s", after: "g1")))
        #expect(reached.contains(SidebarDocTarget(section: "s", before: "g2")))
        #expect(reached.contains(SidebarDocTarget(section: "s", after: "g2")))
        #expect(!reached.contains { $0.parent != nil })
    }

    @Test func draggedWorkspaceStillDropsIntoAndInsideGroups() throws {
        // A workspace drag (empty table: every place takes it) keeps the into band and the member slots.
        let into = try #require(probe(50, [:]))
        #expect(into.target == SidebarDocTarget(section: "s", parent: "g1"))
        let inside = try #require(probe(65, [:]))
        #expect(inside.target == SidebarDocTarget(section: "s", parent: "g1", before: "m1"))
        let outOfGroup = try #require(probe(25, [:]))
        #expect(outOfGroup.target == SidebarDocTarget(section: "s", before: "w1"))
    }

    @Test func groupThatTakesNothingStaysRefused() throws {
        // Another machine's group whose header sides are refused too: the member row stays refused.
        var table = Self.groupDrag
        table["g1"] = SidebarDocAcceptance(before: false, into: false, after: false, refusal: "cross_machine")
        let refused = try #require(probe(65, table))
        #expect(refused.target == nil)
        #expect(refused.refusal == "nesting")
    }
}
