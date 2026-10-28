import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Groups inside groups, any depth (nested-groups prototype, user 2026-10-21: "perf left alignment is
/// different; ensure from first principles this is not possible"). Every row's x comes from one rule,
/// level × step from the drawn tree (`SidebarIndent`, `SidebarRow.indentLevel`): rows at one level share one x
/// in every group, after a drag and after a reload, and a stale stored depth or a missing parent can
/// never move a group in beside its siblings.
@MainActor @Suite(.serialized) struct SidebarNestedGroupAlignmentTests {
    static func list(_ sections: [SidebarSection], width: CGFloat = 288) -> SidebarListView {
        _ = NSApplication.shared
        let list = SidebarListView(model: SidebarModel(sections: sections))
        list.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
        list.reload(animated: false)
        return list
    }

    /// The x of every drawn header and workspace row, by its level.
    static func xByLevel(_ list: SidebarListView) -> [Int: Set<CGFloat>] {
        var out: [Int: Set<CGFloat>] = [:]
        for row in list.displayed.rows {
            switch row.key {
            // A header's frame reaches left over its rail (`railReach`, Lawrence 2026-10-23); its level's x is its members'.
            case .group, .workspace: out[row.indentLevel, default: []].insert(list.frame(for: row).minX + list.railReach(for: row))
            default: continue
            }
        }
        return out
    }

    static func expectAligned(_ list: SidebarListView, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for (level, xs) in xByLevel(list) {
            #expect(xs.count == 1, "\(label): level \(level) draws at \(xs.sorted())", sourceLocation: sourceLocation)
            let expected = list.inset + list.indent.offset(level: level, width: list.indentWidth)
            #expect(xs.first == expected, "\(label): level \(level) at \(xs.sorted()), the rule says \(expected)", sourceLocation: sourceLocation)
        }
    }

    static func nodes(_ list: SidebarListView) -> [SidebarNode] { list.model.sections.flatMap(\.nodes) }

    @Test(arguments: SidebarNestedFixture.Scenario.allCases)
    func rowsAtOneLevelShareOneX(_ scenario: SidebarNestedFixture.Scenario) {
        let fixture = SidebarNestedFixture(scenario: scenario)
        Self.expectAligned(Self.list(fixture.sections, width: fixture.width), scenario.rawValue)
    }

    /// Six levels draw six levels: a top-level group's rows flush with ungrouped rows (#23975), each deeper
    /// level one step further in, up to the cap.
    @Test func eachLevelIsOneStepIn() {
        let list = Self.list(SidebarNestedFixture(scenario: .deep).sections)
        let levels = Self.xByLevel(list)
        #expect(levels.keys.max() == 6, "a member of the sixth group level is at level 6")
        if let ungrouped = levels[0] { #expect(levels[1] == ungrouped, "a top-level group's rows keep the ungrouped rows' x") }
        let cap = list.indent.visualCap(width: list.indentWidth)
        for level in 2...(cap + 1) {
            guard let x = levels[level]?.first, let above = levels[level - 1]?.first else { continue }
            #expect(x - above == list.indent.step, "level \(level) is one step in from level \(level - 1)")
        }
    }

    /// The user's case: Perf stored under Panes & layout draws as its subgroup, inside its rail, and the
    /// rail of Panes & layout runs on to Perf's last row; a level-0 group draws at level 0 whatever depth it stores.
    @Test func aSubgroupSitsInsideItsParentsRail() throws {
        let list = Self.list(SidebarNestedFixture(scenario: .after).sections)
        let lines = list.groupLines(list.displayed)
        let panes = try #require(lines.first { $0.group == GroupID("g-panes") })
        let perf = try #require(lines.first { $0.group == GroupID("g-perf") })
        let perfLast = try #require(list.displayed.row(for: .workspace(WorkspaceID("w-ws-switch"))))
        #expect(panes.frame.maxY >= list.frame(for: perfLast).minY, "the parent's rail reaches the subgroup's last row")
        #expect(perf.frame.minX > panes.frame.minX, "the subgroup's rail is inside the parent's")
        let panesHeader = try #require(list.displayed.row(for: .group(GroupID("g-panes"))))
        let perfHeader = try #require(list.displayed.row(for: .group(GroupID("g-perf"))))
        let perfMember = try #require(list.displayed.row(for: .workspace(WorkspaceID("w-tab-switch"))))
        let panesMember = try #require(list.displayed.row(for: .workspace(WorkspaceID("w-split-spring"))))
        #expect(list.frame(for: perfMember).minX == list.frame(for: panesMember).minX + list.indent.step,
                "a subgroup's members step in one level from its parent's")
        // A top-level header keeps its edge padding (`groupEdgePadding`, b5400e7e342), so the gap between the
        // two headers can be less than one step; the subgroup's header is still right of its parent's.
        #expect(list.frame(for: perfHeader).minX > list.frame(for: panesHeader).minX,
                "a subgroup's header steps in: it can never read as a sibling")
        #expect(list.frame(for: perfHeader).minX + list.railReach(for: perfHeader) == list.frame(for: perfMember).minX,
                "a header sits at its members' x, its bar reaching left over their rail")
        #expect(perf.frame.minX == list.frame(for: perfHeader).minX, "the subgroup's rail starts at its header bar's left edge")
        #expect(perf.level == 1 && panes.level == 0)
        #expect(SidebarGroupLine.opacity(level: 1) < SidebarGroupLine.opacity(level: 0), "a nested rail is fainter")
    }

    /// A stale stored depth, a parent this list does not draw, or a parent cycle never indents a group.
    @Test func aStaleDepthOrMissingParentNeverIndents() {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func group(_ id: String, parent: String?, depth: Int) -> SidebarNode {
            var g = SidebarGroup(id: GroupID(id), name: id, workspaces: [SidebarWorkspace(id: WorkspaceID("w-\(id)"), title: id)])
            g.parent = parent.map(GroupID.init)
            g.depth = depth
            return .group(g)
        }
        let sections = [SidebarSection(kind: .machine(machine), nodes: [
            group("a", parent: nil, depth: 0),
            group("stale", parent: nil, depth: 1), // a stored depth with no parent
            group("orphan", parent: "gone", depth: 1), // a parent in another room
            group("x", parent: "y", depth: 1), group("y", parent: "x", depth: 1), // a cycle, listed child first
        ])]
        let list = Self.list(sections)
        for id in ["a", "stale", "orphan", "x"] {
            #expect(list.displayed.row(for: .group(GroupID(id)))?.depth == 0, "\(id) draws at the top level")
        }
        Self.expectAligned(list, "stale")
    }

    /// After a drag out of a nested group (the outliner drop the geometry picks) and after a reload into a new
    /// list (a relaunch), rows at one level still share one x.
    @Test func alignedAfterADragOutAndAfterAReload() throws {
        let fixture = SidebarNestedFixture(scenario: .after)
        let list = Self.list(fixture.sections)
        // Perf's last row, the pointer at level 0's x: the drop goes after Panes & layout, at the top level.
        let last = try #require(list.displayed.row(for: .workspace(WorkspaceID("w-ws-switch"))))
        let geometry = Self.geometry(list)
        let point = CGPoint(x: list.inset + 2, y: list.frame(for: last).maxY - 2)
        let hit = try #require(geometry.hit(point))
        #expect(hit.zone == .after)
        #expect(hit.target == SidebarDocTarget(section: "machine", parent: nil, after: "g-panes"), "the drop leaves both groups")
        // The pointer at Perf's members' x keeps it in Perf; a step left of it, it goes after Perf inside Panes & layout.
        let inPerf = try #require(geometry.hit(CGPoint(x: list.inset + list.indent.step + 2, y: point.y)))
        #expect(inPerf.target == SidebarDocTarget(section: "machine", parent: "g-perf", after: "w-ws-switch"))
        let inPanes = try #require(geometry.hit(CGPoint(x: list.inset + list.indent.step * 0.75, y: point.y)))
        #expect(inPanes.target == SidebarDocTarget(section: "machine", parent: "g-panes", after: "g-perf"))

        // Apply the top-level drop: Perf leaves Panes & layout (as the document's move does), then a new list draws it.
        var nodes = Self.nodes(list)
        let at = try #require(nodes.firstIndex { if case let .group(g) = $0 { g.id == GroupID("g-perf") } else { false } })
        guard case var .group(perf) = nodes[at] else { return }
        perf.parent = nil
        nodes[at] = .group(perf)
        let moved = [SidebarSection(kind: list.model.sections[0].kind, nodes: nodes)]
        list.model.setSections(moved)
        list.reload(animated: false)
        #expect(list.displayed.row(for: .group(GroupID("g-perf")))?.depth == 0)
        Self.expectAligned(list, "after the drag")
        let reloaded = Self.list(moved)
        Self.expectAligned(reloaded, "after a reload")
        #expect(reloaded.displayed.rows.map { reloaded.frame(for: $0) } == list.displayed.rows.map { list.frame(for: $0) },
                "a reload draws every row where the drop left it")
    }

    /// The width-free offset (`SidebarRow.groupGutter`, `SidebarStyle.groupOffset`) never traps and keeps the level cap.
    @Test func anUnboundedWidthKeepsTheLevelCap() {
        let indent = SidebarIndent(step: 8)
        #expect(indent.visualCap(width: .greatestFiniteMagnitude) == indent.maxVisualLevels)
        #expect(indent.offset(level: 3, width: .infinity) == 16)
        #expect(indent.offset(level: 99, width: .greatestFiniteMagnitude) == CGFloat(indent.maxVisualLevels) * 8)
    }

    /// A narrow sidebar stops indenting at the cap: the deepest labels keep their width.
    @Test func aNarrowSidebarCapsTheIndent() {
        let fixture = SidebarNestedFixture(scenario: .narrow)
        let list = Self.list(fixture.sections, width: fixture.width)
        let cap = list.indent.visualCap(width: list.indentWidth)
        // Since rows run to 1.5 pt from the right edge (157597d79a2) 196 pt fits one more level; it still stops short.
        #expect(cap < list.indent.maxVisualLevels, "196 pt does not fit every level: the indent stops at \(cap)")
        let deepest = list.displayed.rows.filter { row in
            switch row.key {
            case .group, .workspace: row.indentLevel >= cap + 1
            default: false
            }
        }
        #expect(!deepest.isEmpty)
        for row in deepest {
            let frame = list.frame(for: row)
            #expect(frame.minX + list.railReach(for: row) == list.inset + CGFloat(cap) * list.indent.step, "\(row.key) draws at the cap")
            #expect(frame.width >= list.indent.minimumLabelWidth - 1, "\(row.key) keeps \(frame.width) pt for its label")
        }
        Self.expectAligned(list, "narrow")
    }

    /// A collapsed group holding subgroups shows their unread total and loading on its header.
    @Test func aCollapsedParentRollsUpItsSubtree() throws {
        let list = Self.list(SidebarNestedFixture(scenario: .collapsed).sections)
        #expect(list.displayed.row(for: .group(GroupID("g-lawrence"))) == nil, "a folded group hides its subgroups")
        let header = try #require(list.rowViews[.group(GroupID("g-builders"))] as? GroupHeaderRowView)
        #expect(header.debugBadge == .count(1), "DerivedData sweep, two levels under Builders, is unread")
        #expect(header.debugActivityVisible, "Build queue and SwiftPM cache load under it")
        let sidebar = try #require(list.rowViews[.group(GroupID("g-sidebar"))] as? GroupHeaderRowView)
        #expect(sidebar.debugBadge == .count(3))
    }

    /// The drop geometry over the list as drawn, with the outliner rule on.
    static func geometry(_ list: SidebarListView) -> SidebarDragGeometry {
        var slots: [SidebarDragGeometry.Slot] = []
        for row in list.displayed.rows {
            let frame = list.frame(for: row)
            switch row.key {
            case let .group(id):
                let parent = list.groups[id]?.parent?.rawValue
                slots.append(.init(key: id.rawValue, item: id.rawValue, section: "machine", parent: parent, frame: frame, kind: .group))
            case let .workspace(id):
                slots.append(.init(key: id.rawValue, item: id.rawValue, section: "machine", parent: row.group?.rawValue, frame: frame, kind: .row))
            default: continue
            }
        }
        var geometry = SidebarDragGeometry(slots: slots, acceptance: [:])
        geometry.outline = (list.indent, list.inset, list.indentWidth)
        return geometry
    }
}
