@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSettings
import CmuxNextSidebar
import Testing

/// `workspaces.newPlacement` (cx-plf5): where a new workspace whose entry
/// point names no place lands in the daemon's durable order, through the
/// same slot and reorder plan a row drag uses (`WorkspaceSlotTests`).
struct NewWorkspaceDefaultSlotTests {
    typealias Entry = WorkspaceMovePlan.Entry
    static let section = WorkspaceSlotTests.section

    /// Where new workspace "n" lands; the daemon made it last (`created`).
    static func land(_ placement: NewWorkspacePlacement, current: String? = nil, home: String? = nil,
                     window: [SidebarRowSection], daemon: [Entry]) -> WorkspaceMovePlanTests.Daemon {
        let rule = NewWorkspaceDefaultSlot(placement: placement, current: current)
        guard let slot = rule.slot(for: "n", section: section, in: window, home: home) else {
            return WorkspaceMovePlanTests.Daemon(order: WorkspaceSlotTests.created(daemon))
        }
        return WorkspaceSlotTests.land("n", at: slot, window: window, daemon: WorkspaceSlotTests.created(daemon))
    }

    @Test func topPutsItFirst() {
        let result = Self.land(.top, current: "b", window: WorkspaceMovePlanTests.window(["a", "b", "c"]),
                               daemon: WorkspaceMovePlanTests.plain(["a", "b", "c"]))
        #expect(result.ids(in: nil) == ["n", "a", "b", "c"])
    }

    @Test func topIsAboveGroupsAndNeverJoinsOne() {
        let daemon = [Entry(id: "a"), Entry(id: "g1", group: "g")]
        let result = Self.land(.top, current: "g1", window: WorkspaceMovePlanTests.window(["a"], groups: [("g", ["g1"])]), daemon: daemon)
        #expect(result.ids(in: nil) == ["n", "a"])
        #expect(result.ids(in: "g") == ["g1"])
    }

    @Test func topStaysBelowTheHomeRow() {
        let result = Self.land(.top, home: "h", window: WorkspaceMovePlanTests.window(["h", "a"]), daemon: WorkspaceMovePlanTests.plain(["h", "a"]))
        #expect(result.ids(in: nil) == ["h", "n", "a"])
    }

    @Test func afterCurrentPutsItRightAfterTheShownWorkspace() {
        let result = Self.land(.afterCurrent, current: "b", window: WorkspaceMovePlanTests.window(["a", "b", "c"]),
                               daemon: WorkspaceMovePlanTests.plain(["a", "b", "c"]))
        #expect(result.ids(in: nil) == ["a", "b", "n", "c"])
    }

    @Test func afterCurrentJoinsTheCurrentWorkspacesGroup() {
        let daemon = [Entry(id: "a"), Entry(id: "x", group: "g"), Entry(id: "y", group: "g")]
        let result = Self.land(.afterCurrent, current: "x", window: WorkspaceMovePlanTests.window(["a"], groups: [("g", ["x", "y"])]),
                               daemon: daemon)
        #expect(result.ids(in: "g") == ["x", "n", "y"])
        #expect(result.ids(in: nil) == ["a"])
    }

    /// A pinned workspace shows in the Pinned section, not the machine
    /// section; Home and a workspace of another machine are not there either.
    @Test(arguments: [nil, "pinned", "h"])
    func afterCurrentFallsBackToTopWhenTheCurrentWorkspaceIsNotListed(current: String?) {
        let result = Self.land(.afterCurrent, current: current, home: "h", window: WorkspaceMovePlanTests.window(["a", "b"]),
                               daemon: WorkspaceMovePlanTests.plain(["h", "pinned", "a", "b"]))
        #expect(result.ids(in: nil) == ["h", "pinned", "n", "a", "b"])
    }

    @Test func bottomKeepsTheDaemonsPlace() {
        let rule = NewWorkspaceDefaultSlot(placement: .bottom, current: "a")
        #expect(rule.slot(for: "n", section: Self.section, in: WorkspaceMovePlanTests.window(["a", "b"]), home: nil) == nil)
    }
}
