@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSidebar
import Testing

/// A tab dragged onto a sidebar gap while it is the last tab of its
/// workspace moves that workspace to the gap (REWRITE.md round 3). The
/// sidebar resolves the gap with the dragged workspace's row still shown
/// (`SidebarTabDrop.newWorkspace`, "nothing is excluded"), while the reorder
/// plan counts slots after the moved rows are removed (`DropPosition`).
/// `WorkspaceMovePlan.excluding` converts one to the other; each test runs
/// the converted slot through the same plan a row drag uses and checks where
/// the workspace really lands in cmux-tui's durable order.
struct TabDropWorkspaceSlotTests {
    typealias Entry = WorkspaceMovePlan.Entry

    static func land(_ id: String, tabDropIndex index: Int, group: String? = nil, window: [SidebarRowSection],
                     daemon: [Entry]) -> WorkspaceMovePlanTests.Daemon {
        let raw = DropPosition(section: .machine(.local), group: group.map(GroupID.init), index: index)
        let position = WorkspaceMovePlan.excluding([id], from: raw, in: window)
        var simulated = WorkspaceMovePlanTests.Daemon(order: daemon)
        for command in WorkspaceMovePlan.commands(for: position, moving: [SidebarWorkspaceID(id)], window: window, daemon: daemon) ?? [] {
            simulated.apply(command)
        }
        return simulated
    }

    /// The reported bug: moving a workspace to a lower slot by dragging its
    /// last tab onto the gap below the next row.
    @Test func gapBelowTheNextRowPutsTheWorkspaceThere() {
        let window = WorkspaceMovePlanTests.window(["x", "y", "c"])
        // The gap between y and c: index 2 with x still counted.
        let result = Self.land("x", tabDropIndex: 2, window: window, daemon: WorkspaceMovePlanTests.plain(["x", "y", "c"]))
        #expect(result.ids(in: nil) == ["y", "x", "c"])
    }

    @Test func gapBelowTheLastRowPutsTheWorkspaceLast() {
        let window = WorkspaceMovePlanTests.window(["x", "y", "c"])
        let result = Self.land("x", tabDropIndex: 3, window: window, daemon: WorkspaceMovePlanTests.plain(["x", "y", "c"]))
        #expect(result.ids(in: nil) == ["y", "c", "x"])
    }

    @Test func gapAboveKeepsItsSlot() {
        let window = WorkspaceMovePlanTests.window(["a", "b", "x"])
        let result = Self.land("x", tabDropIndex: 1, window: window, daemon: WorkspaceMovePlanTests.plain(["a", "b", "x"]))
        #expect(result.ids(in: nil) == ["a", "x", "b"])
    }

    /// With groups the sidebar lists ungrouped rows first while the durable
    /// order interleaves them; the old root-index path sent that sidebar
    /// index to `move-workspace` on the durable order.
    @Test func interleavedDurableOrderStillLandsBelowTheNextRow() {
        let daemon = [Entry(id: "x"), Entry(id: "g1", group: "g"), Entry(id: "y"), Entry(id: "c")]
        let window = WorkspaceMovePlanTests.window(["x", "y", "c"], groups: [("g", ["g1"])])
        let result = Self.land("x", tabDropIndex: 2, window: window, daemon: daemon)
        #expect(result.ids(in: nil) == ["y", "x", "c"])
        #expect(result.ids(in: "g") == ["g1"])
    }

    @Test func gapInsideItsOwnGroupCountsWithoutIt() {
        let daemon = [Entry(id: "x", group: "g"), Entry(id: "a", group: "g"), Entry(id: "b", group: "g")]
        let window = WorkspaceMovePlanTests.window([], groups: [("g", ["x", "a", "b"])])
        // The gap between a and b inside g.
        let result = Self.land("x", tabDropIndex: 2, group: "g", window: window, daemon: daemon)
        #expect(result.ids(in: "g") == ["a", "x", "b"])
    }

    @Test func gapInAnotherGroupJoinsIt() {
        let daemon = [Entry(id: "x"), Entry(id: "a", group: "g"), Entry(id: "b", group: "g")]
        let window = WorkspaceMovePlanTests.window(["x"], groups: [("g", ["a", "b"])])
        let result = Self.land("x", tabDropIndex: 1, group: "g", window: window, daemon: daemon)
        #expect(result.ids(in: "g") == ["a", "x", "b"])
        #expect(result.ids(in: nil).isEmpty)
    }
}

/// R15 (nxdog26): a tab dropped on a sidebar gap makes a new workspace,
/// which must land in that gap. The commit resolves the gap the sidebar
/// drew (`SidebarTabDropTarget.lastDrop`, `WorkspaceSlot.at`) once the
/// daemon reports the workspace at the end of its order; each test runs
/// that through the row-drag plan and checks cmux-tui's durable order.
struct TabDropNewWorkspaceSlotTests {
    typealias Entry = WorkspaceMovePlan.Entry

    static func land(new id: String, gap index: Int, group: String? = nil, window before: [SidebarRowSection],
                     claimed after: [SidebarRowSection], daemon: [Entry]) -> WorkspaceMovePlanTests.Daemon {
        let slot = WorkspaceSlot.at(DropPosition(section: .machine(.local), group: group.map(GroupID.init), index: index))
        _ = before
        var simulated = WorkspaceMovePlanTests.Daemon(order: daemon)
        guard let position = slot.position(moving: [id], section: .machine(.local), in: after) else { return simulated }
        for command in WorkspaceMovePlan.commands(for: position, moving: [SidebarWorkspaceID(id)], window: after, daemon: daemon) ?? [] {
            simulated.apply(command)
        }
        return simulated
    }

    @Test func aGapBetweenLooseRowsWithAGroupPresent() {
        // Sidebar: a, b (loose), then group g (g1). Gap between a and b.
        let before = WorkspaceMovePlanTests.window(["a", "b"], groups: [("g", ["g1"])])
        let after = WorkspaceMovePlanTests.window(["a", "b", "n"], groups: [("g", ["g1"])])
        let daemon = [Entry(id: "g1", group: "g"), Entry(id: "a"), Entry(id: "b"), Entry(id: "n")]
        let result = Self.land(new: "n", gap: 1, window: before, claimed: after, daemon: daemon)
        #expect(result.ids(in: nil) == ["a", "n", "b"])
    }

    @Test func theFirstGap() {
        let before = WorkspaceMovePlanTests.window(["a", "b"])
        let after = WorkspaceMovePlanTests.window(["a", "b", "n"])
        let result = Self.land(new: "n", gap: 0, window: before, claimed: after, daemon: WorkspaceMovePlanTests.plain(["a", "b", "n"]))
        #expect(result.ids(in: nil) == ["n", "a", "b"])
    }

    @Test func aGapInsideAGroup() {
        let before = WorkspaceMovePlanTests.window(["a"], groups: [("g", ["g1", "g2"])])
        let after = WorkspaceMovePlanTests.window(["a", "n"], groups: [("g", ["g1", "g2"])])
        let daemon = [Entry(id: "a"), Entry(id: "g1", group: "g"), Entry(id: "g2", group: "g"), Entry(id: "n")]
        let result = Self.land(new: "n", gap: 1, group: "g", window: before, claimed: after, daemon: daemon)
        #expect(result.ids(in: "g") == ["g1", "n", "g2"])
    }

    /// The daemon order interleaves workspaces of other windows; the gap is
    /// this window's.
    @Test func otherWindowsWorkspacesDoNotShiftTheGap() {
        let before = WorkspaceMovePlanTests.window(["a", "b"])
        let after = WorkspaceMovePlanTests.window(["a", "b", "n"])
        let daemon = WorkspaceMovePlanTests.plain(["x1", "a", "x2", "b", "n"])
        let result = Self.land(new: "n", gap: 1, window: before, claimed: after, daemon: daemon)
        let mine = result.ids(in: nil).filter { ["a", "b", "n"].contains($0) }
        #expect(mine == ["a", "n", "b"])
    }
}
