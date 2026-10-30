import AppKit
import CmuxNextDesign
import Foundation
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-23: "dragging groups to reorder around is kinda jank... would be nice if groups that are too
/// tall, when i drag around, get a max height, animated, so i can see." A real list, a tall group's header pressed
/// and dragged through `updateDrag` one step at a time, every row's frame recorded at each step.
///
/// The rules (plans/cmux-next/sidebar-owner.md, "Group drag: design for the rewrite"):
/// - a lifted group taller than its header and three rows is cut to that height; the gap it opens is that height;
/// - the drop slot is a function of the pointer alone: the same pointer y always shows the same rows, a still
///   pointer changes nothing, and a 1 pt move back and forth over a boundary always shows the same two layouts;
/// - one step never moves a row by more than the (capped) gap;
/// - after a drop or a cancel every row is at rest at its layout frame, and the document gets the drop the gap showed.
///
/// The list: loose `w1`, `w2`, the tall group `tall` (eight members), short groups `s1` (one member) and `s2` (two
/// members), loose `w3`.
@MainActor @Suite(.serialized) struct SidebarTallGroupDragTests {
    static let section = "sec"
    static let tall = GroupID("tall"), s1 = GroupID("s1"), s2 = GroupID("s2")

    final class Drops {
        var targets: [SidebarDocTarget] = []
    }

    static func ws(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    static func node(_ name: String) -> SidebarNode {
        switch name {
        case "tall": .group(SidebarGroup(id: tall, name: "Tall", color: .purple, workspaces: (1...8).map { ws("t\($0)") }))
        case "s1": .group(SidebarGroup(id: s1, name: "Short", color: .green, workspaces: [ws("a1")]))
        case "s2": .group(SidebarGroup(id: s2, name: "Pair", color: .red, workspaces: [ws("b1"), ws("b2")]))
        default: .workspace(ws(name))
        }
    }

    static func sections(_ order: [String]) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return [SidebarSection(kind: .machine(machine), nodes: order.map(node))]
    }

    static let start = ["w1", "w2", "tall", "s1", "s2", "w3"]

    static func list(_ drops: Drops) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: sections(start), activeWorkspaceID: WorkspaceID("w1"))
        let members = Set((1...8).map { "t\($0)" } + ["a1", "b1", "b2"])
        model.docDrag = SidebarDocDrag(item: { key in
            switch key {
            case let .workspace(id): "w_\(id.rawValue)"
            case let .group(group): "g_\(group.rawValue)"
            default: nil
            }
        }, section: { _ in section }, begin: { _ in
            // What `drag_begin` gives for a dragged group: beside the top-level rows, never among a group's members.
            var table: [String: SidebarDocAcceptance] = [section: SidebarDocAcceptance(before: false, into: true, after: false)]
            for loose in ["w1", "w2", "w3"] { table["w_\(loose)"] = SidebarDocAcceptance(before: true, into: false, after: true) }
            for group in [tall, s1, s2] { table["g_\(group.rawValue)"] = SidebarDocAcceptance(before: true, into: false, after: true) }
            for member in members { table["w_\(member)"] = SidebarDocAcceptance(before: false, into: false, after: false, refusal: "nesting") }
            return table
        }, drop: { [drops] _, target in drops.targets.append(target) })
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 900))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        return (list, window)
    }

    /// The tall group's height cut to its header and three rows, and the gap that card opens (its height and the
    /// spacing to the next block), from the list at rest.
    static func expected(_ list: SidebarListView) throws -> (cap: CGFloat, gap: CGFloat, full: CGFloat) {
        let header = try #require(list.displayed.row(for: .group(tall)))
        let third = try #require(list.displayed.row(for: .workspace(WorkspaceID("t3"))))
        let last = try #require(list.displayed.row(for: .workspace(WorkspaceID("t8"))))
        let next = try #require(list.displayed.row(for: .group(s1)))
        let cap = third.maxY - header.y
        return (cap, cap + next.y - last.maxY, last.maxY - header.y)
    }

    /// Every row the list shows that the drag does not carry: its layout y and its view's frame.
    struct Shot: Equatable {
        var layout: [SidebarRowKey: CGFloat]
        var views: [SidebarRowKey: CGRect]
    }

    static func shot(_ list: SidebarListView) -> Shot {
        let hidden = list.drag?.hiddenKeys ?? []
        var shot = Shot(layout: [:], views: [:])
        for row in list.displayed.rows where !hidden.contains(row.key) {
            shot.layout[row.key] = row.y
            if let view = list.rowViews[row.key] { shot.views[row.key] = view.frame }
        }
        return shot
    }

    /// Presses the tall group's header and lifts it; returns the press point.
    static func lift(_ list: SidebarListView) throws -> NSPoint {
        let header = try #require(list.displayed.row(for: .group(tall)))
        let start = NSPoint(x: 80, y: header.y + header.height / 2)
        list.press = SidebarPress(key: header.key, point: start)
        list.beginDrag(try #require(list.press))
        try #require(list.drag != nil, "the group did not lift")
        return start
    }

    static func move(_ list: SidebarListView, to y: CGFloat) {
        list.updateDrag(windowPoint: list.convert(NSPoint(x: 80, y: y), to: nil))
    }

    static func describe(_ list: SidebarListView) -> String {
        let rows = list.displayed.rows.map { "\($0.key)@\(Int($0.y))" }
        return "rows \(rows); gap \(String(describing: list.displayed.gapY)) +\(list.displayed.gapShift); "
            + "card \(list.drag?.lift.frame ?? .zero)"
    }

    /// The lifted card is cut to the header and three rows, and the gap is the cut card's, not the whole group's.
    @Test func aTallGroupLiftsAsACappedCardWithACappedGap() throws {
        let (list, window) = Self.list(Drops())
        defer { window.close() }
        let expected = try Self.expected(list)
        let start = try Self.lift(list)
        let drag = try #require(list.drag)
        #expect(abs(drag.lift.frame.height - expected.cap) < 0.5,
                "the card is \(drag.lift.frame.height) pt tall, not the header and three rows (\(expected.cap) of \(expected.full))")
        Self.move(list, to: start.y + 1)
        #expect(abs(list.displayed.gapShift - expected.gap) < 0.5,
                "the gap is \(list.displayed.gapShift) pt, not the capped card's \(expected.gap): \(Self.describe(list))")
        list.cancelDrag()
    }

    /// Down to the bottom and back up to the top, 3 pt a step: no row moves by more than the capped gap in one step,
    /// a still pointer changes nothing, and each pointer y shows the same rows going down as going up.
    @Test func eachStepMovesRowsByAtMostTheGapAndThePointerAloneDecides() throws {
        let (list, window) = Self.list(Drops())
        defer { window.close() }
        let expected = try Self.expected(list)
        let start = try Self.lift(list)
        let bottom = try #require(list.displayed.rows.last).maxY + 20
        var seen: [Int: Shot] = [:]
        var last = Self.shot(list)
        var ys = Array(stride(from: start.y, through: bottom, by: 3))
        ys += Array(stride(from: bottom, through: 0, by: -3))
        ys += Array(stride(from: 0, through: start.y, by: 3))
        for y in ys {
            Self.move(list, to: y)
            let now = Self.shot(list)
            for (key, ry) in now.layout {
                guard let before = last.layout[key] else { continue }
                #expect(abs(ry - before) <= expected.gap + 0.5,
                        "pointer \(y): \(key) moved \(ry - before) pt in one step (the gap is \(expected.gap)): \(Self.describe(list))")
            }
            Self.move(list, to: y)
            #expect(Self.shot(list) == now, "pointer \(y): a still pointer moved the rows")
            if let earlier = seen[Int(y.rounded())] {
                #expect(earlier.layout == now.layout, "pointer \(y): the rows differ from the last time the pointer was here")
            }
            seen[Int(y.rounded())] = now
            last = now
        }
        list.cancelDrag()
    }

    /// Over the first boundary below the start (where the gap first moves), 1 pt back and forth, five times: each
    /// side always shows the same rows.
    @Test func aOnePointWiggleOverABoundaryNeverOscillates() throws {
        let (list, window) = Self.list(Drops())
        defer { window.close() }
        let start = try Self.lift(list)
        let rest = Self.shot(list).layout
        var y = start.y
        while Self.shot(list).layout == rest, y < 900 {
            y += 1
            Self.move(list, to: y)
        }
        try #require(y < 900, "the gap never moved: \(Self.describe(list))")
        let above = y - 1
        Self.move(list, to: above)
        let upper = Self.shot(list).layout
        Self.move(list, to: y)
        let lower = Self.shot(list).layout
        #expect(upper != lower, "the boundary is not between \(above) and \(y)")
        for _ in 0..<5 {
            Self.move(list, to: above)
            #expect(Self.shot(list).layout == upper, "pointer \(above): the rows flipped: \(Self.describe(list))")
            Self.move(list, to: y)
            #expect(Self.shot(list).layout == lower, "pointer \(y): the rows flipped: \(Self.describe(list))")
        }
        list.cancelDrag()
    }

    /// Every row at its layout frame, opaque, nothing hidden or lifted, no gap, and the layout is the model's.
    static func expectAtRest(_ list: SidebarListView, _ when: String) {
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        #expect(list.drag == nil && list.landing == nil && list.settling == nil, "\(when): the drag did not end")
        #expect(!list.subviews.contains { $0 is DragLiftView }, "\(when): the lifted card is still there")
        #expect(list.suppressed.isEmpty, "\(when): rows stay hidden: \(list.suppressed)")
        #expect(list.displayed.gapY == nil, "\(when): a gap stays open")
        let fresh = SidebarLayout.make(sections: list.listSections, metrics: list.metrics, options: list.options(includeGap: false))
        #expect(list.displayed.rows.map(\.key) == fresh.rows.map(\.key) && list.displayed.rows.map(\.y) == fresh.rows.map(\.y),
                "\(when): the list does not show the model's layout: \(Self.describe(list))")
        for row in list.displayed.rows {
            guard let view = list.rowViews[row.key] else { continue }
            #expect(view.frame == list.frame(for: row), "\(when): \(row.key) is at \(view.frame), not \(list.frame(for: row))")
            #expect(view.alphaValue == 1, "\(when): \(row.key) is see-through (\(view.alphaValue))")
        }
    }

    /// Down until the gap stands right after `s1`, by the pointer alone, then let go: the document gets that drop,
    /// and once the model shows it the rows are at rest.
    @Test func aDropGoesWhereTheGapShowedAndTheRowsComeToRest() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops)
        defer { window.close() }
        let start = try Self.lift(list)
        var y = start.y
        func gapAfterS1() -> Bool {
            guard let gap = list.displayed.gapY, let a1 = list.displayed.row(for: .workspace(WorkspaceID("a1"))),
                  let s2 = list.displayed.row(for: .group(Self.s2)) else { return false }
            return a1.maxY <= gap + 0.5 && s2.y > gap
        }
        while !gapAfterS1(), y < 900 {
            y += 2
            Self.move(list, to: y)
        }
        try #require(gapAfterS1(), "the gap never stood after s1: \(Self.describe(list))")
        list.finishDrag()
        #expect(drops.targets == [SidebarDocTarget(section: Self.section, after: "g_s1")], "drops: \(drops.targets)")
        list.model.sections = Self.sections(["w1", "w2", "s1", "tall", "s2", "w3"])
        _ = list.showModelChange(animates: true)
        Self.expectAtRest(list, "after the drop")
    }

    /// Down past both short groups, then cancelled: nothing is sent and the rows are back at rest where they were.
    @Test func aCancelPutsEveryRowBackAtRest() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops)
        defer { window.close() }
        let before = list.displayed.rows.map(\.y)
        let start = try Self.lift(list)
        for step in 1...40 { Self.move(list, to: start.y + CGFloat(step) * 6) }
        list.cancelDrag()
        #expect(drops.targets.isEmpty, "a cancel sent \(drops.targets)")
        Self.expectAtRest(list, "after the cancel")
        #expect(list.displayed.rows.map(\.y) == before, "the rows did not go back where they were")
    }
}
