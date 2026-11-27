import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Group reorder with nested groups on (u9772, "reordering groups in sidebar is very buggy now").
///
/// Since the reducer lets a drag nest a group (a283 slice 2), its acceptance table takes a dragged group beside
/// another group's members and into its header. A plain reorder must still move the dragged group among the list's
/// top-level blocks: the drop goes before or after a whole group, never into it, and a group with subgroups is one
/// block (header, members, subgroups and their members) that lifts, swaps and lands as one.
///
/// The list: loose `top`, group `p` (member `a`) with subgroup `s` (member `b`), group `q` (member `c`), group
/// `r` (member `d`).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarGroupReorderNestingTests {
    static let section = "sec"

    final class Drops {
        var targets: [SidebarDocTarget] = []
    }

    static func list(_ drops: Drops) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        var sub = SidebarGroup(id: GroupID("s"), name: "Sub", color: .blue, workspaces: [ws("b")])
        sub.parent = GroupID("p")
        sub.depth = 1
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(ws("top")),
                .group(SidebarGroup(id: GroupID("p"), name: "Parent", color: .purple, workspaces: [ws("a")])),
                .group(sub),
                .group(SidebarGroup(id: GroupID("q"), name: "Q", color: .green, workspaces: [ws("c")])),
                .group(SidebarGroup(id: GroupID("r"), name: "R", color: .red, workspaces: [ws("d")])),
            ]),
        ], activeWorkspaceID: WorkspaceID("top"))
        let parents: [String: String] = ["a": "g_p", "b": "g_s", "c": "g_q", "d": "g_r"]
        model.docDrag = SidebarDocDrag(item: { key in
            switch key {
            case let .workspace(id): "w_\(id.rawValue)"
            case let .group(group): "g_\(group.rawValue)"
            default: nil
            }
        }, section: { _ in section }, begin: { items in
            // What `drag_begin` gives a dragged one-level group since nested groups (bdbf63b5483): it may go
            // beside any row and into any group header (the tree stays within three levels).
            var table: [String: SidebarDocAcceptance] = [section: SidebarDocAcceptance(before: false, into: true, after: false)]
            table["w_top"] = SidebarDocAcceptance(before: true, into: false, after: true)
            for group in ["p", "s", "q", "r"] {
                table["g_\(group)"] = SidebarDocAcceptance(before: true, into: true, after: true)
            }
            for member in parents.keys { table["w_\(member)"] = SidebarDocAcceptance(before: true, into: false, after: true) }
            // The dragged group and everything under it refuse with `self`.
            let refused = SidebarDocAcceptance(before: false, into: false, after: false, refusal: "self")
            for item in items {
                table[item] = refused
                for (member, parent) in parents where parent == item { table["w_\(member)"] = refused }
                if item == "g_p" { table["g_s"] = refused; table["w_b"] = refused }
            }
            return table
        }, drop: { [drops] _, target in drops.targets.append(target) })
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        return (list, window)
    }

    /// The rows of group `id` and every group under it, as shown now: the header to the last row deeper than it.
    static func blockRows(_ list: SidebarListView, _ id: String) throws -> [SidebarRow] {
        let rows = list.displayed.rows
        let start = try #require(rows.firstIndex { $0.key == .group(GroupID(id)) })
        var end = start + 1
        while end < rows.count, rows[end].depth > rows[start].depth { end += 1 }
        return Array(rows[start..<end])
    }

    static func block(_ list: SidebarListView, _ id: String) throws -> ClosedRange<CGFloat> {
        let rows = try blockRows(list, id)
        let first = try #require(rows.first), last = try #require(rows.last)
        return first.y...last.maxY
    }

    static func lift(_ list: SidebarListView, _ id: String) throws -> NSPoint {
        let header = try #require(list.displayed.row(for: .group(GroupID(id))))
        let start = NSPoint(x: 80, y: header.y + header.height / 2)
        list.press = SidebarPress(key: header.key, point: start)
        list.beginDrag(try #require(list.press))
        try #require(list.drag != nil, "the group did not lift")
        return start
    }

    /// Lifts group `id`, then moves the pointer so that `edge(card)` lands at `y`, in steps.
    static func drag(_ list: SidebarListView, _ id: String, to y: (_ card: CGRect) -> CGFloat) throws {
        let start = try lift(list, id)
        let dy = y(list.drag!.lift.frame)
        for step in 1...6 {
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: start.y + dy * CGFloat(step) / 6), to: nil))
        }
    }

    static func drop(_ list: SidebarListView) {
        list.finishDrag()
        if let landing = list.landing { list.finishLand(landing, then: nil) }
    }

    /// A group dragged down past an open group goes after that whole group, not in among its members. The slot
    /// rule (`SidebarGroupDragPlan.slot`): the card's top passes the block's middle in the list without the card
    /// (r is drawn below the open gap, so its base is its drawn place less the gap).
    @Test func aGroupDraggedPastAnOpenGroupGoesAfterItNotIntoIt() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops)
        defer { window.close() }
        try Self.drag(list, "q") { card in
            let r = (try? Self.block(list, "r")) ?? 0...0
            let mid = (r.lowerBound + r.upperBound) / 2 - list.displayed.gapShift
            return mid + 1 - card.minY
        }
        Self.drop(list)
        #expect(drops.targets == [SidebarDocTarget(section: Self.section, after: "g_r")], "drops: \(drops.targets)")
    }

    /// A group dragged up past an open group with a subgroup goes before that whole tree, at the top level.
    @Test func aGroupDraggedUpPastAParentGoesBeforeItsWholeTree() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops)
        defer { window.close() }
        let p = try Self.block(list, "p")
        let mid = (p.lowerBound + p.upperBound) / 2
        try Self.drag(list, "q") { card in mid - 1 - card.minY }
        Self.drop(list)
        #expect(drops.targets == [SidebarDocTarget(section: Self.section, after: "w_top")], "drops: \(drops.targets)")
    }

    /// A group held where it was (below a parent with a subgroup) shows its gap after the subgroup, where it came
    /// from: not between the parent's members and its subgroup. Dropped there it moves nothing (no move is sent).
    @Test func aGroupHeldBelowAParentShowsItsGapAfterTheSubgroup() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops)
        defer { window.close() }
        try Self.drag(list, "q") { _ in 2 }
        let s = try Self.block(list, "s")
        let gapY = try #require(list.displayed.gapY, "no gap shows")
        #expect(gapY >= s.upperBound - 0.5, "the gap opens at \(gapY), inside the parent's block (subgroup ends at \(s.upperBound))")
        Self.drop(list)
        #expect(drops.targets.isEmpty, "a drop where the group came from sent \(drops.targets)")
    }

    /// A parent group lifts with its subgroup: the card carries the subgroup's header and members, and the gap it
    /// leaves is the whole tree's height.
    @Test func aParentLiftsWithItsSubgroups() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops)
        defer { window.close() }
        let tree = try Self.block(list, "p")
        _ = try Self.lift(list, "p")
        let drag = try #require(list.drag)
        #expect(drag.hiddenKeys.contains(.group(GroupID("s"))), "the subgroup's header stays in the list")
        #expect(drag.hiddenKeys.contains(.workspace(WorkspaceID("b"))), "the subgroup's member stays in the list")
        #expect(abs(drag.lift.frame.height - (tree.upperBound - tree.lowerBound)) < 1,
                "the card is \(drag.lift.frame.height) pt, the tree \(tree.upperBound - tree.lowerBound) pt")
        list.cancelDrag()
    }

    /// The list's blocks keep a group's subgroups (deeper rows) in the group's block.
    @Test func blocksKeepSubgroupsInTheirTopLevelGroup() {
        let p = GroupID("p"), s = GroupID("s")
        func row(_ key: SidebarRowKey, _ y: CGFloat, group: GroupID? = nil, depth: Int = 0) -> SidebarRow {
            var row = SidebarRow(key: key, y: y, height: 20, section: .pinned, group: group, siblingIndex: 0, parentIndex: nil,
                                 isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil)
            row.depth = depth
            return row
        }
        let rows = [
            row(.workspace(WorkspaceID("top")), 0),
            row(.group(p), 20, group: p),
            row(.workspace(WorkspaceID("a")), 40, group: p, depth: 1),
            row(.group(s), 60, group: s, depth: 1),
            row(.workspace(WorkspaceID("b")), 80, group: s, depth: 2),
            row(.workspace(WorkspaceID("x")), 100),
        ]
        #expect(SidebarGroupDragPlan.blocks(of: rows).map(\.range) == [0...20, 20...100, 100...120])
    }
}
