import CmuxNextDesign
import CoreGraphics
@testable import CmuxNextSidebar
import Testing

/// User 2026-10-21 (screenshot 10.07.20 PM): the "Perf" group, its line and its rows sat one gutter
/// right of "Panes & layout" and "Nightly & CI". A group dragged into the gap under another group's last
/// member was made that group's subgroup (depth 1), and the list draws whatever depth it is given.
///
/// The invariants: every top-level group's header, line and member rows start at the same x; a
/// group's depth comes only from a parent group the list really holds (a stale depth draws top level);
/// and a dragged group never lands one level in through a member row's gap.
@MainActor struct SidebarGroupAlignmentTests {
    private let panes = GroupID("g_panes"), perf = GroupID("g_perf"), nightly = GroupID("g_nightly")

    private func group(_ id: GroupID, parent: GroupID? = nil, depth: Int = 0, _ members: [String]) -> SidebarNode {
        var made = SidebarGroup(id: id, name: id.rawValue, workspaces: members.map { SidebarWorkspace(id: WorkspaceID($0), title: $0) })
        made.parent = parent
        made.depth = depth
        return .group(made)
    }

    private func section(_ nodes: [SidebarNode]) -> SidebarSection {
        SidebarSection(kind: .machine(SidebarMachine(id: MachineID("mini"), name: "mini", kind: .server)), nodes: nodes)
    }

    /// The rows as the list draws them from what the model holds (the model's set is the one way in).
    private func rows(_ nodes: [SidebarNode]) -> [SidebarRow] {
        let model = SidebarModel(sections: [section(nodes)])
        model.setSections([section(nodes)]) // a reload: the daemon's next list
        return SidebarLayout.make(sections: model.sections, metrics: .standard, options: SidebarLayoutOptions()).rows
    }

    private func gutter(_ rows: [SidebarRow], _ key: SidebarRowKey) -> CGFloat? { rows.first { $0.key == key }?.groupGutter }

    /// Each group's line x (its header's x plus the bar's), the way `SidebarGroupLine.lines` places it.
    private func lineX(_ rows: [SidebarRow]) -> [GroupID: CGFloat] {
        let lines = SidebarGroupLine.lines(rows, colors: [:]) { row in
            CGRect(x: row.groupGutter, y: row.y, width: 200, height: row.height)
        }
        return Dictionary(uniqueKeysWithValues: lines.map { ($0.group, $0.frame.minX) })
    }

    private func expectAligned(_ rows: [SidebarRow], groups: [GroupID], members: [String]) {
        let headers = Set(groups.compactMap { gutter(rows, .group($0)) })
        #expect(headers == [0], "every top-level header at the list's inset: \(headers)")
        let memberGutters = Set(members.compactMap { gutter(rows, .workspace(WorkspaceID($0))) })
        #expect(memberGutters == [0], "every member at the ungrouped rows' edge: \(memberGutters)")
        let lines = lineX(rows)
        #expect(Set(groups.compactMap { lines[$0] }) == [SidebarStyle.groupLineX(membersMinX: 0)], "one line x: \(lines)")
        #expect(groups.allSatisfy { lines[$0] != nil })
    }

    @Test func topLevelGroupsShareHeaderLineAndRowOffsets() {
        let rows = rows([group(panes, ["p1", "p2"]), group(perf, ["f1", "f2"]), group(nightly, ["n1"])])
        expectAligned(rows, groups: [panes, perf, nightly], members: ["p1", "p2", "f1", "f2", "n1"])
    }

    /// The screenshot's data shape after a reload: Perf carries depth 1 but no parent the list holds
    /// (its parent closed, or a stale depth on the wire). It draws top level, not one gutter in.
    @Test(arguments: [(GroupID?.none, 1), (GroupID("g_gone"), 1), (GroupID("g_gone"), 2)])
    func aStaleDepthDrawsAtTheTopLevel(parent: GroupID?, depth: Int) {
        let rows = rows([group(panes, ["p1"]), group(perf, parent: parent, depth: depth, ["f1"]), group(nightly, ["n1"])])
        expectAligned(rows, groups: [panes, perf, nightly], members: ["p1", "f1", "n1"])
    }

    /// A subgroup the user made on purpose still steps its members in, from its listed parent.
    @Test func aRealSubgroupIndentsFromItsListedParent() {
        let rows = rows([group(panes, ["p1"]), group(perf, parent: panes, depth: 5, ["f1"]), group(nightly, ["n1"])])
        #expect(rows.first { $0.key == .group(perf) }?.depth == 1, "depth from the parent (1), not the wire's 5")
        #expect(gutter(rows, .workspace(WorkspaceID("f1"))) == SidebarStyle.groupGutter, "its members one gutter in")
        #expect(gutter(rows, .group(nightly)) == 0)
    }

    // MARK: Drag reorder

    typealias Slot = SidebarDragGeometry.Slot

    /// Panes 0..20 with p1 20..40 and its subgroup Sub 40..60 holding s1 60..80; Perf 80..100 with f1 100..120.
    private static let slots: [Slot] = [
        Slot(key: "g_panes", item: "g_panes", section: "m", frame: rect(0), kind: .group),
        Slot(key: "p1", item: "p1", section: "m", parent: "g_panes", frame: rect(20), kind: .row),
        Slot(key: "g_sub", item: "g_sub", section: "m", parent: "g_panes", frame: rect(40), kind: .group),
        Slot(key: "s1", item: "s1", section: "m", parent: "g_sub", frame: rect(60), kind: .row),
        Slot(key: "g_perf", item: "g_perf", section: "m", frame: rect(80), kind: .group),
        Slot(key: "f1", item: "f1", section: "m", parent: "g_perf", frame: rect(100), kind: .row),
    ]

    private static func rect(_ y: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 200, height: 20) }

    /// `drag_begin` for dragging top-level Perf: only top-level gaps and headers' middles ("into") take it.
    private static let perfDrag: [String: SidebarDocAcceptance] = [
        "g_panes": SidebarDocAcceptance(before: true, into: true, after: true),
        "p1": SidebarDocAcceptance(before: false, into: false, after: false, refusal: "nesting"),
        "g_sub": SidebarDocAcceptance(before: false, into: true, after: false, refusal: nil),
        "s1": SidebarDocAcceptance(before: false, into: false, after: false, refusal: "nesting"),
        "g_perf": SidebarDocAcceptance(before: false, into: false, after: false, refusal: "self"),
        "f1": SidebarDocAcceptance(before: false, into: false, after: false, refusal: "self"),
    ]

    /// Under Panes' last row (its subgroup's member): the drop goes after the whole of Panes at the top
    /// level, never into Panes or its subgroup.
    @Test func aGroupDraggedUnderAnotherGroupsLastRowStaysTopLevel() throws {
        let geometry = SidebarDragGeometry(slots: Self.slots, acceptance: Self.perfDrag)
        let hit = try #require(geometry.hit(CGPoint(x: 100, y: 75)))
        #expect(hit.target == SidebarDocTarget(section: "m", after: "g_panes"))
        // Every point over Panes' block lands at the top level, or into a header on purpose.
        for y in stride(from: CGFloat(0), to: 80, by: 1) {
            let target = try #require(geometry.hit(CGPoint(x: 100, y: y))?.target, "y \(y) takes a drop")
            let intoHeader = target.parent != nil && target.before == nil && target.after == nil
            #expect(target.parent == nil || intoHeader, "y \(y): \(target)")
        }
    }
}
