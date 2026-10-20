import CmuxNextBridge
@testable import CmuxNextSidebar
import Testing

/// Group ordering verbs (plans/cmux-next/sidebar-ordering-AUDIT.md, Lawrence 2026-10-19: "I need
/// an option to move a group to the top"). `SidebarEdits.groupIndex` gives the section-row index
/// `.reorderGroup` takes. Before it, Move Group Up/Down passed the group's index among the room's
/// groups, while the intent counts every row of the section: with loose rows above the groups,
/// Move Down sent the first group up among the loose rows and Move Up sent the second group to the
/// very top.
@Suite struct SidebarGroupOrderTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let g1 = GroupID("g1"), g2 = GroupID("g2")

    static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    /// Loose `a`, `b`; group `g1` (`c`); group `g2` (`d`, `e`, collapsed); loose `f`.
    static func sections(g2Collapsed: Bool = true, g1Collapsed: Bool = false) -> [SidebarSection] {
        [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(row("a")), .workspace(row("b")),
            .group(SidebarGroup(id: g1, name: "one", isCollapsed: g1Collapsed, workspaces: [row("c")])),
            .group(SidebarGroup(id: g2, name: "two", isCollapsed: g2Collapsed, workspaces: [row("d"), row("e")])),
            .workspace(row("f")),
        ])]
    }

    static func order(_ sections: [SidebarSection]) -> [String] {
        sections[0].nodes.map { node in
            switch node {
            case let .workspace(ws): ws.id.rawValue
            case let .group(group): group.id.rawValue
            case let .item(item): item.id
            }
        }
    }

    /// The section's row order after moving `group` by `move`, as the verb does it.
    static func moved(_ group: GroupID, _ move: SidebarGroupMove) throws -> [String] {
        var sections = sections()
        let index = try #require(SidebarEdits.groupIndex(group, move, in: sections), "\(move) of \(group.rawValue) found no index")
        #expect(SidebarEdits.apply(.reorderGroup(group, index: index), to: &sections))
        return order(sections)
    }

    @Test func moveToTopGoesAboveEveryRow() throws {
        #expect(try Self.moved(Self.g2, .top) == ["g2", "a", "b", "g1", "f"])
    }

    @Test func moveToBottomGoesBelowEveryRow() throws {
        #expect(try Self.moved(Self.g1, .bottom) == ["a", "b", "g2", "f", "g1"])
    }

    @Test func moveDownStepsBelowTheNextRow() throws {
        #expect(try Self.moved(Self.g1, .down) == ["a", "b", "g2", "g1", "f"])
    }

    @Test func moveUpStepsAboveTheRowAbove() throws {
        #expect(try Self.moved(Self.g2, .up) == ["a", "b", "g2", "g1", "f"])
        #expect(try Self.moved(Self.g1, .up) == ["a", "g1", "b", "g2", "f"])
    }

    @Test func aMoveThatChangesNothingHasNoIndex() throws {
        var sections = Self.sections()
        let top = try #require(SidebarEdits.groupIndex(Self.g2, .top, in: sections))
        SidebarEdits.apply(.reorderGroup(Self.g2, index: top), to: &sections)
        #expect(SidebarEdits.groupIndex(Self.g2, .top, in: sections) == nil)
        #expect(SidebarEdits.groupIndex(Self.g2, .up, in: sections) == nil)
        #expect(SidebarEdits.groupIndex(GroupID("missing"), .down, in: sections) == nil)
    }

    /// Collapse Other Groups (Slack's "Collapse all other sections"): every other expanded group
    /// folds, and the kept group opens when it was folded.
    @Test func collapseOthersTogglesTheOtherOpenGroupsAndOpensThisOne() {
        let open = Self.sections(g2Collapsed: false)
        #expect(SidebarEdits.groupsToggledByCollapsingOthers(keeping: Self.g1, in: open) == [Self.g2])
        let folded = Self.sections(g2Collapsed: false, g1Collapsed: true)
        #expect(SidebarEdits.groupsToggledByCollapsingOthers(keeping: Self.g1, in: folded) == [Self.g1, Self.g2])
        #expect(SidebarEdits.groupsToggledByCollapsingOthers(keeping: Self.g1, in: Self.sections()).isEmpty)
    }

    /// A multi-selection moved to the top of its group lands there as one block, in sidebar order.
    @Test func selectionMovesToTheTopOfItsGroupAsOneBlock() throws {
        // Group `g2` holds `d`, `e`, `x`; the selection is `x` and `e`, right-clicked on `x`.
        var sections = [SidebarSection(kind: .machine(Self.machine), nodes: [
            .workspace(Self.row("a")),
            .group(SidebarGroup(id: Self.g2, name: "two", workspaces: [Self.row("d"), Self.row("e"), Self.row("x")])),
        ])]
        let moving = SidebarEdits.treeOrder([WorkspaceID("x"), WorkspaceID("e")], in: sections)
        #expect(moving.map(\.rawValue) == ["e", "x"], "the block keeps sidebar order")
        let position = try #require(WorkspaceSlot.top(anchor: "x").position(moving: ["x", "e"], section: .machine(.local), in: sections))
        #expect(position.group == Self.g2 && position.index == 0)
        #expect(SidebarEdits.apply(.reorder(moving, to: position), to: &sections))
        let members = sections[0].nodes.compactMap { node -> [String]? in
            if case let .group(group) = node, group.id == Self.g2 { group.workspaces.map(\.id.rawValue) } else { nil }
        }.first
        #expect(members == ["e", "x", "d"])
    }
}
