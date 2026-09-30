@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSidebar
import Testing

/// Workspace verbs that place a workspace (New Workspace Above/Below/at
/// Top/at Bottom/in This Group, Move to Top/Bottom, a double-click in a
/// group) resolve a `WorkspaceSlot` against the window's sidebar and run
/// the row-drag reorder plan; each test checks where the workspace lands in
/// cmux-tui's durable order, the way `WorkspaceMovePlanTests` does.
struct WorkspaceSlotTests {
    typealias Entry = WorkspaceMovePlan.Entry
    static let section = SectionID.machine(.local)

    static func land(_ id: String, at slot: WorkspaceSlot, window: [SidebarRowSection], daemon: [Entry]) -> WorkspaceMovePlanTests.Daemon {
        var simulated = WorkspaceMovePlanTests.Daemon(order: daemon)
        guard let position = slot.position(moving: [id], section: section, in: window) else { return simulated }
        for command in WorkspaceMovePlan.commands(for: position, moving: [SidebarWorkspaceID(id)], window: window, daemon: daemon) ?? [] {
            simulated.apply(command)
        }
        return simulated
    }

    /// A workspace the daemon just created: last in the durable order, not
    /// yet in the window's sidebar.
    static func created(_ ids: [Entry], new id: String = "n") -> [Entry] { ids + [Entry(id: id)] }

    @Test func newWorkspaceBelowLandsRightAfterTheAnchor() {
        let window = WorkspaceMovePlanTests.window(["a", "b", "c"])
        let result = Self.land("n", at: .below("a"), window: window, daemon: Self.created(WorkspaceMovePlanTests.plain(["a", "b", "c"])))
        #expect(result.ids(in: nil) == ["a", "n", "b", "c"])
    }

    @Test func newWorkspaceAboveLandsRightBeforeTheAnchor() {
        let window = WorkspaceMovePlanTests.window(["a", "b", "c"])
        let result = Self.land("n", at: .above("c"), window: window, daemon: Self.created(WorkspaceMovePlanTests.plain(["a", "b", "c"])))
        #expect(result.ids(in: nil) == ["a", "b", "n", "c"])
    }

    @Test func newWorkspaceAtTopLandsFirst() {
        let window = WorkspaceMovePlanTests.window(["a", "b"])
        let result = Self.land("n", at: .top(anchor: nil), window: window, daemon: Self.created(WorkspaceMovePlanTests.plain(["a", "b"])))
        #expect(result.ids(in: nil) == ["n", "a", "b"])
    }

    @Test func newWorkspaceAtBottomStaysLastAmongLooseRowsWithGroups() {
        let daemon = [Entry(id: "a"), Entry(id: "g1", group: "g"), Entry(id: "b")]
        let window = WorkspaceMovePlanTests.window(["a", "b"], groups: [("g", ["g1"])])
        let result = Self.land("n", at: .bottom(anchor: nil), window: window, daemon: Self.created(daemon))
        #expect(result.ids(in: nil) == ["a", "b", "n"])
        #expect(result.ids(in: "g") == ["g1"])
    }

    @Test func belowAGroupedAnchorJoinsItsGroup() {
        let daemon = [Entry(id: "a"), Entry(id: "x", group: "g"), Entry(id: "y", group: "g")]
        let window = WorkspaceMovePlanTests.window(["a"], groups: [("g", ["x", "y"])])
        let result = Self.land("n", at: .below("x"), window: window, daemon: Self.created(daemon))
        #expect(result.ids(in: "g") == ["x", "n", "y"])
        #expect(result.ids(in: nil) == ["a"])
    }

    @Test func endOfGroupAppendsToTheGroup() {
        let daemon = [Entry(id: "x", group: "g"), Entry(id: "a"), Entry(id: "y", group: "g")]
        let window = WorkspaceMovePlanTests.window(["a"], groups: [("g", ["x", "y"])])
        let result = Self.land("n", at: .endOfGroup(GroupID("g")), window: window, daemon: Self.created(daemon))
        #expect(result.ids(in: "g") == ["x", "y", "n"])
    }

    @Test func moveToBottomOfItsOwnGroupKeepsItGrouped() {
        let daemon = [Entry(id: "x", group: "g"), Entry(id: "y", group: "g"), Entry(id: "z", group: "g")]
        let window = WorkspaceMovePlanTests.window([], groups: [("g", ["x", "y", "z"])])
        let result = Self.land("x", at: .bottom(anchor: "x"), window: window, daemon: daemon)
        #expect(result.ids(in: "g") == ["y", "z", "x"])
    }

    @Test func moveToTopOfTheLooseRows() {
        let window = WorkspaceMovePlanTests.window(["a", "b", "c"])
        let result = Self.land("c", at: .top(anchor: "c"), window: window, daemon: WorkspaceMovePlanTests.plain(["a", "b", "c"]))
        #expect(result.ids(in: nil) == ["c", "a", "b"])
    }

    @Test func moveToBottomOfTheLooseRows() {
        let window = WorkspaceMovePlanTests.window(["a", "b", "c"])
        let result = Self.land("a", at: .bottom(anchor: "a"), window: window, daemon: WorkspaceMovePlanTests.plain(["a", "b", "c"]))
        #expect(result.ids(in: nil) == ["b", "c", "a"])
    }

    @Test func missingAnchorOrGroupHasNoPosition() {
        let window = WorkspaceMovePlanTests.window(["a"])
        #expect(WorkspaceSlot.below("zz").position(moving: ["n"], section: Self.section, in: window) == nil)
        #expect(WorkspaceSlot.endOfGroup(GroupID("nope")).position(moving: ["n"], section: Self.section, in: window) == nil)
    }

    // MARK: Sort

    @Test func sortByNameUsesFinderOrder() {
        let sorted = WorkspaceSortKey.name.sorted(["1", "2", "3"], names: ["1": "web 10", "2": "api", "3": "web 9"], directories: [:], recency: [])
        #expect(sorted == ["2", "3", "1"])
    }

    @Test func sortByDirectoryPutsWorkspacesWithoutOneLast() {
        let sorted = WorkspaceSortKey.directory.sorted(["1", "2", "3"], names: ["1": "b", "2": "a", "3": "c"],
                                                       directories: ["1": "/src/zed", "3": "/src/cmux"], recency: [])
        #expect(sorted == ["3", "1", "2"])
    }

    @Test func sortByLastUsedIsMostRecentFirst() {
        let sorted = WorkspaceSortKey.lastUsed.sorted(["1", "2", "3", "4"], names: [:], directories: [:], recency: ["3", "1"])
        #expect(sorted == ["3", "1", "2", "4"])
    }

    // MARK: Recency

    @Test func windowRecencyTracksShownWorkspaces() {
        let state = WindowState(workspaceID: "a")
        state.workspaceID = "b"
        state.workspaceID = "c"
        state.workspaceID = "b"
        #expect(state.workspaceRecency == ["b", "c", "a"])
        #expect(state.lastUsedWorkspace == "c")
    }
}
