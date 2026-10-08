import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Lawrence 2026-10-07 (nxdog68, groups option B): "dragging grouped
/// workspaces around, animation feels weird, the workspaces inside
/// disappear". A group drag hid the member rows in the list but lifted only
/// the header, so the members were drawn nowhere until the drop landed.
/// Every member row stays drawn during and after each drag: whole group,
/// inside its group, out of it, into another group.
@MainActor @Suite struct SidebarGroupDragRowsTests {
    final class Harness {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
        let sidebar: SidebarView
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        var list: SidebarListView { sidebar.list }

        init() {
            sidebar = SidebarView(model: model)
            window.isReleasedWhenClosed = false
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
            window.contentView?.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
        }

        func frame(_ key: SidebarRowKey) throws -> NSRect { list.frame(for: try #require(list.displayed.row(for: key))) }

        /// Presses `key` at its middle and moves the pointer 2 pt at a time
        /// (down, or up for a negative `direction`) until `until` holds, at most 400 pt.
        @discardableResult
        func drag(_ key: SidebarRowKey, direction: CGFloat = 1, until: () -> Bool) throws -> Bool {
            let from = try frame(key)
            let press = NSPoint(x: from.minX + 40, y: from.midY)
            list.beginDrag(SidebarListView.Press(key: key, point: press))
            for step in 1...200 {
                list.updateDrag(windowPoint: list.convert(NSPoint(x: press.x, y: press.y + direction * CGFloat(step) * 2), to: nil))
                if until() { return true }
            }
            return false
        }

        /// The displayed order of one section's rows: loose ids, group ids, members as `G1.g1`.
        func order() -> [String] {
            list.displayed.rows.compactMap { row -> String? in
                guard row.section == local else { return nil }
                switch row.key {
                case let .group(group): return group.rawValue
                case let .workspace(ws): return row.group.map { "\($0.rawValue).\(ws.rawValue)" } ?? ws.rawValue
                default: return nil
                }
            }
        }

        /// The workspace rows the user sees: drawn in the list, or carried on the lifted card.
        func drawnWorkspaces() -> Set<String> {
            var drawn = Set<String>()
            for (key, view) in list.rowViews where view.alphaValue > 0.5 && !view.isHidden {
                if case let .workspace(ws) = key { drawn.insert(ws.rawValue) }
            }
            if let lift = list.drag?.lift { collect(in: lift, into: &drawn) }
            return drawn
        }

        private func collect(in view: NSView, into drawn: inout Set<String>) {
            for sub in view.subviews where !sub.isHidden && sub.alphaValue > 0.5 {
                if let row = sub as? WorkspaceRowView, case let .workspace(ws) = row.key { drawn.insert(ws.rawValue) }
                collect(in: sub, into: &drawn)
            }
        }

        /// Member rows of `group` in the displayed layout, top to bottom, each with a visible view.
        func shownMembers(_ group: GroupID) -> [String] {
            list.displayed.rows.compactMap { row -> String? in
                guard row.group == group, case let .workspace(ws) = row.key,
                      let view = list.rowViews[row.key], view.alphaValue > 0.5 else { return nil }
                return ws.rawValue
            }
        }
    }

    @Test func aDraggedGroupCarriesItsMembersAndTheyStayAfterTheDrop() throws {
        let h = Harness()
        defer { h.window.close() }
        let moved = ["a", "b", "G1", "G1.g1", "G1.g2", "G1.g3", "G2", "c"]
        #expect(try h.drag(.group(g1)) { h.order() == moved }, "the group makes way past b (order: \(h.order()))")
        let drawn = h.drawnWorkspaces()
        #expect(["g1", "g2", "g3"].allSatisfy(drawn.contains), "the members ride on the lifted group (drawn: \(drawn.sorted()))")
        let lift = try #require(h.list.drag?.lift.frame)
        let block = try h.frame(.group(g1)).union(try h.frame(.workspace(id("g3"))))
        #expect(abs(lift.height - block.height) < 1, "the card is the whole group block")
        h.list.finishDrag()
        #expect(shape(h.model.sections, local) == "a b G1[g1,g2,g3] G2[h1,h2] c")
        #expect(h.shownMembers(g1) == ["g1", "g2", "g3"])
        #expect(h.list.drag == nil)
    }

    /// Esc during a group drag: the block flies back and every row shows again.
    @Test func aCancelledGroupDragPutsEveryRowBack() throws {
        let h = Harness()
        defer { h.window.close() }
        let moved = ["a", "b", "G1", "G1.g1", "G1.g2", "G1.g3", "G2", "c"]
        #expect(try h.drag(.group(g1)) { h.order() == moved })
        #expect(["g1", "g2", "g3"].allSatisfy(h.drawnWorkspaces().contains), "drawn: \(h.drawnWorkspaces().sorted())")
        h.list.cancelDrag()
        #expect(shape(h.model.sections, local) == "a G1[g1,g2,g3] b G2[h1,h2] c")
        #expect(h.shownMembers(g1) == ["g1", "g2", "g3"])
        #expect(h.list.rowViews[.group(g1)]?.alphaValue == 1)
        #expect(h.list.suppressed.isEmpty)
    }

    @Test func aMemberDraggedInsideItsGroupKeepsEveryRow() throws {
        let h = Harness()
        defer { h.window.close() }
        let moved = ["a", "G1", "G1.g2", "G1.g3", "G1.g1", "b", "G2", "c"]
        #expect(try h.drag(.workspace(id("g1"))) { h.order() == moved }, "order: \(h.order())")
        #expect(["g2", "g3"].allSatisfy(h.drawnWorkspaces().contains))
        h.list.finishDrag()
        #expect(shape(h.model.sections, local) == "a G1[g2,g3,g1] b G2[h1,h2] c")
        #expect(h.shownMembers(g1) == ["g2", "g3", "g1"])
    }

    @Test func aMemberDraggedOutOfItsGroupLeavesTheOthersDrawn() throws {
        let h = Harness()
        defer { h.window.close() }
        let moved = ["a", "G1", "G1.g1", "G1.g3", "b", "g2", "G2", "c"]
        #expect(try h.drag(.workspace(id("g2"))) { h.order() == moved }, "order: \(h.order())")
        h.list.finishDrag()
        #expect(shape(h.model.sections, local) == "a G1[g1,g3] b g2 G2[h1,h2] c")
        #expect(h.shownMembers(g1) == ["g1", "g3"])
        #expect(h.list.rowViews[.workspace(id("g2"))]?.alphaValue == 1)
    }

    /// cx-7pnn: a member dropped onto a loose row groups with that row; its
    /// old group keeps its other members, drawn.
    @Test func aMemberDroppedOntoALooseRowGroupsAndTheOldGroupKeepsItsRows() throws {
        let h = Harness()
        defer { h.window.close() }
        #expect(try h.drag(.workspace(id("g3"))) { h.list.drag?.target == .ontoWorkspace(id("b")) })
        h.list.finishDrag()
        let local = try #require(h.model.sections.first { $0.id == SectionID.machine(.local) })
        let groups = local.nodes.compactMap { node -> SidebarGroup? in if case let .group(g) = node { g } else { nil } }
        #expect(groups.first { $0.id == g1 }?.workspaces.map(\.id.rawValue) == ["g1", "g2"], "the old group keeps g1 and g2")
        #expect(groups.contains { $0.id != g1 && $0.id != g2 && Set($0.workspaces.map(\.id.rawValue)) == ["b", "g3"] }, "a new group of b and g3 (\(shape(h.model.sections, SectionID.machine(.local))))")
        #expect(h.shownMembers(g1) == ["g1", "g2"])
    }

    @Test func aMemberDroppedIntoAnotherGroupJoinsIt() throws {
        let h = Harness()
        defer { h.window.close() }
        h.model.send(.toggleCollapse(.group(g2)))
        h.list.reload(animated: false)
        let moved = ["a", "G1", "G1.g1", "G1.g3", "b", "G2", "G2.h1", "G2.g2", "G2.h2", "c"]
        #expect(try h.drag(.workspace(id("g2"))) { h.order() == moved }, "order: \(h.order())")
        h.list.finishDrag()
        #expect(shape(h.model.sections, local) == "a G1[g1,g3] b G2[h1,g2,h2] c")
        #expect(h.shownMembers(g1) == ["g1", "g3"])
        #expect(h.shownMembers(g2) == ["h1", "g2", "h2"])
    }

    /// nxdog70: a drop onto a row made a "New Group" in blue. A new group
    /// never gets blue automatically (nor grey): it takes the group palette.
    @Test func aNewGroupFromADropIsNeverBlue() throws {
        var sections = fixture()
        for color in GroupColor.allCases {
            let color = SidebarGroupBand.newGroupColor(in: sections)
            #expect(color != .blue && color != .grey, "picked \(color)")
            sections[1].nodes.append(.group(SidebarGroup(id: GroupID("n-\(color.rawValue)"), name: "N", color: color, workspaces: [w("z-\(color.rawValue)")])))
        }
        let h = Harness()
        defer { h.window.close() }
        #expect(try h.drag(.workspace(id("c")), direction: -1) { h.list.drag?.target == .ontoWorkspace(id("b")) })
        h.list.finishDrag()
        let made = h.model.sections[1].nodes.compactMap { node -> SidebarGroup? in
            if case let .group(g) = node, g.id != g1, g.id != g2 { g } else { nil }
        }
        #expect(made.count == 1 && made.first?.color != .blue, "made: \(made.map(\.color))")
    }
}
