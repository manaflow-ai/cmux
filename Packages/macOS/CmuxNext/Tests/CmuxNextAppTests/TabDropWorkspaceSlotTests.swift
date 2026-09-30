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
