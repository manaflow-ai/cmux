import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The group reorder rule (`SidebarGroupReorder`, u2455) through the drag path
/// the app uses: the sidebar document's drag (`SidebarModel.docDrag`). A real
/// list, a group header pressed and dragged with `updateDrag`, then the drop's
/// one document move. The list: loose `top`, tall group `g1` (4 members),
/// short group `g2` (1 member), short group `g3` (1 member); with `pinned`, a
/// document Pinned section above it holds group `gp` (1 member).
@MainActor @Suite(.serialized) struct SidebarGroupReorderDocDragTests {
    static let section = "sec"

    final class Drops {
        var targets: [SidebarDocTarget] = []
    }

    static let pinnedSection = "sec_pinned"

    static func list(_ drops: Drops, pinned: Bool = false) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let pinnedBand = SidebarSection(kind: .custom(SidebarCustomSection(id: pinnedSection)), nodes: [
            .group(SidebarGroup(id: GroupID("gp"), name: "Pinned", color: .blue, workspaces: [ws("p")])),
        ])
        let model = SidebarModel(sections: (pinned ? [pinnedBand] : []) + [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(ws("top")),
                .group(SidebarGroup(id: GroupID("g1"), name: "Tall", color: .purple, workspaces: ["a", "b", "c", "d"].map(ws))),
                .group(SidebarGroup(id: GroupID("g2"), name: "Short", color: .green, workspaces: [ws("e")])),
                .group(SidebarGroup(id: GroupID("g3"), name: "Last", color: .red, workspaces: [ws("f")])),
            ]),
        ], activeWorkspaceID: WorkspaceID("top"))
        let members: Set<String> = ["a", "b", "c", "d", "e", "f", "p"]
        model.docDrag = SidebarDocDrag(item: { key in
            switch key {
            case let .workspace(id): "w_\(id.rawValue)"
            case let .group(group): "g_\(group.rawValue)"
            default: nil
            }
        }, section: { id in id == .custom(pinnedSection) ? pinnedSection : section }, begin: { _ in
            // What `drag_begin` gives for a dragged group: groups do not nest.
            var table: [String: SidebarDocAcceptance] = [section: SidebarDocAcceptance(before: false, into: true, after: false)]
            table[pinnedSection] = SidebarDocAcceptance(before: false, into: true, after: false)
            table["w_top"] = SidebarDocAcceptance(before: true, into: false, after: true)
            for group in ["g1", "g2", "g3", "gp"] { table["g_\(group)"] = SidebarDocAcceptance(before: true, into: false, after: true, refusal: nil) }
            for member in members { table["w_\(member)"] = SidebarDocAcceptance(before: false, into: false, after: false, refusal: "nesting") }
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

    /// The block of group `id` (header to last member) in the list as shown now.
    static func block(_ list: SidebarListView, _ id: String) throws -> ClosedRange<CGFloat> {
        let rows = list.displayed.rows.filter { $0.key == .group(GroupID(id)) || $0.group == GroupID(id) }
        let first = try #require(rows.first), last = try #require(rows.last)
        return first.y...last.maxY
    }

    /// Presses group `id`'s header, lifts it, then moves the pointer so that `edge(card)` lands at `y`, in steps.
    static func drag(_ list: SidebarListView, _ id: String, to y: (_ card: CGRect) -> CGFloat) throws {
        let header = try #require(list.displayed.row(for: .group(GroupID(id))))
        let start = NSPoint(x: 80, y: header.y + header.height / 2)
        list.press = SidebarPress(key: header.key, point: start)
        list.beginDrag(try #require(list.press))
        try #require(list.drag != nil, "the group did not lift")
        let dy = y(list.drag!.lift.frame)
        for step in 1...6 {
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: start.y + dy * CGFloat(step) / 6), to: nil))
        }
    }

    static func drop(_ list: SidebarListView) {
        list.finishDrag()
        if let landing = list.landing { list.finishLand(landing, then: nil) }
    }

    /// A tall group moves below a short one as soon as its bottom passes the short one's middle (plus the margin),
    /// while its header is still far above it (the old header-centre rule kept it in place).
    @Test func aTallGroupMovesDownByItsBottomEdge() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops)
        defer { window.close() }
        try Self.drag(list, "g1") { card in
            // g2 as shown with the gap open (pushed down by it), and the card's bottom 1 pt past its middle + margin.
            let g2 = (try? Self.block(list, "g2")) ?? 0...0
            let mid = (g2.lowerBound + g2.upperBound) / 2 + SidebarGroupReorder.hysteresis(for: g2.upperBound - g2.lowerBound)
            #expect(card.minY + 30 < g2.lowerBound, "the header is not far above g2: the test would not tell the rules apart")
            return mid + 1 - card.maxY
        }
        Self.drop(list)
        #expect(drops.targets == [SidebarDocTarget(section: Self.section, before: "g_g3")], "drops: \(drops.targets)")
    }

    /// Short of that margin the tall group stays where it was.
    @Test func aTallGroupShortOfTheMarginStays() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops)
        defer { window.close() }
        try Self.drag(list, "g1") { card in
            let g2 = (try? Self.block(list, "g2")) ?? 0...0
            let mid = (g2.lowerBound + g2.upperBound) / 2 + SidebarGroupReorder.hysteresis(for: g2.upperBound - g2.lowerBound)
            return mid - 2 - card.maxY
        }
        Self.drop(list)
        #expect(drops.targets.allSatisfy { $0 == SidebarDocTarget(section: Self.section, before: "g_g2") }, "drops: \(drops.targets)")
    }

    /// A short group moves above a tall one only when its top passes the tall one's middle (minus the margin).
    @Test func aShortGroupMovesUpPastATallOneByItsTopEdge() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops)
        defer { window.close() }
        let g1 = try Self.block(list, "g1")
        let mid = (g1.lowerBound + g1.upperBound) / 2 - SidebarGroupReorder.hysteresis(for: g1.upperBound - g1.lowerBound)
        // First drag g3 up past g2 (short): now between g1 and g2, then on past g1's middle.
        try Self.drag(list, "g3") { card in mid - 1 - card.minY }
        Self.drop(list)
        #expect(drops.targets == [SidebarDocTarget(section: Self.section, before: "g_g1")], "drops: \(drops.targets)")
    }

    /// Lawrence 2026-10-20: "I can't drag groups to become ordered first." With a section drawn above the machine
    /// rows (Pinned, the top band), the gap above the first machine row probed the end of that section, so the drop
    /// went into Pinned or was refused. It is a drop before the first row, in the machine section.
    @Test func aGroupDragsToTheFirstSlotUnderPinned() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops, pinned: true)
        defer { window.close() }
        let top = try #require(list.displayed.row(for: .workspace(WorkspaceID("top"))))
        let pinned = try Self.block(list, "gp")
        #expect(pinned.upperBound <= top.y, "Pinned is not drawn above the machine rows")
        // g2's top just past the first row's middle (minus the margin), still below Pinned's middle.
        let mid = top.y + top.height / 2 - SidebarGroupReorder.hysteresis(for: top.height)
        try Self.drag(list, "g2") { card in mid - 1 - card.minY }
        Self.drop(list)
        #expect(drops.targets == [SidebarDocTarget(section: Self.section, before: "w_top")], "drops: \(drops.targets)")
    }
}
