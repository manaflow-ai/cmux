import CoreGraphics
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The drag look a retarget draws (`SidebarListView.displayLayout`) is spliced from the drag's base layout
/// (`SidebarDragLook`): the rows before the slot stay, the rows after it move by the dragged block, and only the
/// containers the move touches are laid out again. Leo 2026-11-04: "It should just never, ever ... be acceptable for
/// there to be some sort of linear time growth degradation"; a retarget at 5,000 rows spent 87 of its 93 ms in a full
/// `SidebarLayout.make`.
///
/// For each list shape and each workspace drag, every slot the drag can reach: the splice equals `make` of the moved
/// sections (rows, height and the slot's gapY and gapShift), or says it cannot (nil), and then the list lays out as before.
@MainActor @Suite struct SidebarDragLookSpliceTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let metrics = SidebarLayoutMetrics.standard

    static func ws(_ id: String, title: String? = nil, done: Bool = false) -> SidebarWorkspace {
        var ws = SidebarWorkspace(id: WorkspaceID(id), title: title ?? "workspace \(id)")
        if done { ws.taskStatus = .done }
        return ws
    }

    static func group(_ id: String, _ members: [SidebarWorkspace], name: String? = nil, collapsed: Bool = false,
                      parent: String? = nil, depth: Int = 0) -> SidebarGroup {
        var group = SidebarGroup(id: GroupID(id), name: name ?? "Group \(id)", color: .green, isCollapsed: collapsed, workspaces: members)
        (group.parent, group.depth) = (parent.map(GroupID.init), depth)
        return group
    }

    static func machineSection(_ nodes: [SidebarNode]) -> SidebarSection {
        SidebarSection(kind: .machine(machine), nodes: nodes)
    }

    /// The list shapes the drag harnesses use, and the states a drag meets in them.
    static func shapes() -> [(name: String, sections: [SidebarSection], active: WorkspaceID?)] {
        let tens = (0..<3).map { g in
            SidebarNode.group(group("t\(g)", (0..<10).map { ws("t\(g)-\($0)") }))
        }
        let loose: [SidebarNode] = [.workspace(ws("l0")), .workspace(ws("l1")), .group(group("lg", [ws("lg0"), ws("lg1")])),
                                    .workspace(ws("l2")), .workspace(ws("l3"))]
        let nested: [SidebarNode] = [.group(group("na", [ws("na0"), ws("na1")])),
                                     .group(group("na1", [ws("nb0"), ws("nb1")], parent: "na", depth: 1)),
                                     .group(group("nc", [ws("nc0")])), .workspace(ws("n-loose"))]
        let collapsed: [SidebarNode] = [.group(group("ca", [ws("ca0"), ws("ca1"), ws("ca2")], collapsed: true)),
                                        .group(group("cb", [ws("cb0"), ws("cb1")])), .workspace(ws("c-loose"))]
        let collapsedParent: [SidebarNode] = [.group(group("pa", [ws("pa0")], collapsed: true)),
                                              .group(group("pa1", [ws("pb0"), ws("pb1")], parent: "pa", depth: 1)),
                                              .group(group("pc", [ws("pc0"), ws("pc1")])), .workspace(ws("p-loose"))]
        let sole: [SidebarNode] = [.group(group("solo", [ws("so0", title: "solo")], name: "solo")),
                                   .group(group("duo", [ws("du0", title: "duo"), ws("du1")], name: "duo")),
                                   .group(group("sb", [ws("sb0"), ws("sb1")])), .workspace(ws("s-loose"))]
        let link = SidebarListItem(id: "itm_link", ref: .builtIn(.chief), title: "Link")
        let app = SidebarListItem(id: "itm_app", ref: .builtIn(.chief), title: "App")
        var withItems = group("ia", [])
        withItems.setMembers([.workspace(ws("ia0")), .item(link), .workspace(ws("ia1"))])
        let items: [SidebarNode] = [.group(withItems), .item(app), .group(group("ib", [ws("ib0"), ws("ib1")])), .workspace(ws("i-loose"))]
        let done: [SidebarNode] = [.group(group("da", [ws("da0"), ws("da1", done: true), ws("da2")])),
                                   .group(group("db", [ws("db0"), ws("db1")])), .workspace(ws("d-loose"))]
        let doneLoose: [SidebarNode] = [.workspace(ws("dl0")), .workspace(ws("dl1", done: true)), .group(group("dg", [ws("dg0"), ws("dg1")]))]
        let pinned = SidebarSection(kind: .pinned, nodes: [.workspace(ws("pin0"))])
        return [
            ("groups of 10", [machineSection(tens)], nil),
            ("loose rows", [machineSection(loose)], nil),
            ("nested groups", [machineSection(nested)], nil),
            ("collapsed group", [machineSection(collapsed)], WorkspaceID("ca1")),
            ("collapsed parent", [machineSection(collapsedParent)], nil),
            ("sole member", [machineSection(sole)], nil),
            ("items", [machineSection(items)], nil),
            ("done fold in a group", [machineSection(done)], nil),
            ("done fold at the top level", [machineSection(doneLoose)], nil),
            ("pinned and a machine", [pinned, machineSection(loose)], nil),
        ]
    }

    /// The options the list draws a workspace drag with (`SidebarListView.options`): the look's, with the dragged rows shown.
    static func lookOptions(active: WorkspaceID?) -> SidebarLayoutOptions {
        var o = SidebarLayoutOptions()
        (o.showsSoleMachineHeader, o.foldsDone, o.flattensMachines, o.showEmptyPinned) = (true, true, true, true)
        o.activeWorkspaceID = active
        return o
    }

    /// The workspace drags of a shape: each workspace alone, and the first two of each list together.
    static func drags(_ sections: [SidebarSection]) -> [[WorkspaceID]] {
        var drags: [[WorkspaceID]] = []
        for section in sections {
            drags += section.workspaces.map { [$0.id] }
            for node in section.nodes {
                if case let .group(group) = node, group.workspaces.count >= 2 { drags.append(group.workspaces.prefix(2).map(\.id)) }
            }
            let looseIDs = section.nodes.compactMap { node -> WorkspaceID? in if case let .workspace(ws) = node { ws.id } else { nil } }
            if looseIDs.count >= 2 { drags.append(Array(looseIDs.prefix(2))) }
        }
        return drags
    }

    /// Every slot a drag of `ids` can reach: each section's top level and each group's members, in the coordinates
    /// after the dragged rows are removed (as the drop resolver names them), one past the end included.
    static func slots(_ sections: [SidebarSection], without ids: [WorkspaceID]) -> [DropPosition] {
        var removed = sections
        _ = SidebarEdits.removeWorkspaces(Set(ids), from: &removed)
        var slots: [DropPosition] = []
        for section in removed {
            slots += (0...section.nodes.count).map { DropPosition(section: section.id, index: $0) }
            for node in section.nodes {
                guard case let .group(group) = node else { continue }
                slots += (0...group.members.count).map { DropPosition(section: section.id, group: group.id, index: $0) }
            }
        }
        return slots
    }

    /// The look `displayLayout` drew before the splice: `make` of the moved sections, then the slot's gap.
    static func made(_ sections: [SidebarSection], moving ids: [WorkspaceID], to position: DropPosition,
                     options o: SidebarLayoutOptions) -> SidebarLayout {
        var moved = sections
        _ = SidebarEdits.reorder(ids, to: position, in: &moved, prunes: false)
        var layout = SidebarLayout.make(sections: moved, metrics: metrics, options: o)
        let hidden = Set(ids.map(SidebarRowKey.workspace))
        let slot = layout.rows.filter { hidden.contains($0.key) }
        if let first = slot.first, let last = slot.last {
            layout.gapY = first.y
            layout.gapShift = last.maxY + metrics.rowSpacing - first.y
        }
        return layout
    }

    /// One shape: every drag to every slot. Returns how many slots spliced and how many fell back.
    static func check(_ name: String, _ sections: [SidebarSection], active: WorkspaceID?, minimal: Bool = false) -> (spliced: Int, fellBack: Int) {
        var (spliced, fellBack) = (0, 0)
        for ids in drags(sections) {
            var look = lookOptions(active: active)
            look.minimal = minimal
            var baseOptions = look
            baseOptions.excludedWorkspaces.formUnion(ids)
            // A drag that carries a Done row draws unfolded (`SidebarListView.options`).
            let dragged = sections.flatMap(\.workspaces).filter { ids.contains($0.id) }
            if SidebarLayout.dragUnfolds(dragged, options: baseOptions) {
                (look.foldsDone, look.foldsArchived, look.archiveSection) = (false, false, false)
                (baseOptions.foldsDone, baseOptions.foldsArchived, baseOptions.archiveSection) = (false, false, false)
            }
            let base = SidebarLayout.make(sections: sections, metrics: metrics, options: baseOptions)
            let splice = SidebarDragLook(base: base, sections: sections, options: look, moving: ids)
            for position in slots(sections, without: ids) {
                guard let layout = splice.layout(to: position, metrics: metrics) else {
                    fellBack += 1
                    continue
                }
                spliced += 1
                let expected = made(sections, moving: ids, to: position, options: look)
                #expect(layout.rows == expected.rows, "\(name): \(ids) to \(position): rows differ")
                #expect(layout.totalHeight == expected.totalHeight, "\(name): \(ids) to \(position): height")
                #expect(layout.gapY == expected.gapY && layout.gapShift == expected.gapShift && layout.gapHeight == expected.gapHeight,
                        "\(name): \(ids) to \(position): gap \(String(describing: layout.gapY)) \(layout.gapShift) vs \(String(describing: expected.gapY)) \(expected.gapShift)")
                #expect(layout == expected, "\(name): \(ids) to \(position)")
                // The spliced layout's key lookups agree with its rows.
                for (i, row) in layout.rows.enumerated() where layout.position(of: row.key) != i {
                    Issue.record("\(name): \(ids) to \(position): \(row.key) indexed at \(String(describing: layout.position(of: row.key))), drawn at \(i)")
                }
            }
        }
        return (spliced, fellBack)
    }

    @Test func everySlotOfEveryShapeSplicesAsMakeLaysItOut() {
        for (name, sections, active) in Self.shapes() {
            let (spliced, fellBack) = Self.check(name, sections, active: active)
            print("DRAG-LOOK-SPLICE shape=\"\(name)\" spliced=\(spliced) fellBack=\(fellBack)")
            #expect(spliced > 0, "\(name): no slot spliced")
        }
    }

    @Test func minimalRowsSpliceAsMakeLaysThemOut() {
        for (name, sections, active) in Self.shapes() {
            _ = Self.check(name + " (minimal)", sections, active: active, minimal: true)
        }
    }

    /// The common case: a workspace dragged within and between groups of one machine section, and out to the top
    /// level, never falls back.
    @Test func groupsOfTenNeverFallBack() throws {
        let shape = try #require(Self.shapes().first)
        let (spliced, fellBack) = Self.check(shape.name, shape.sections, active: nil)
        #expect(fellBack == 0 && spliced > 0, "groups of 10: \(fellBack) slots fell back")
    }
}
