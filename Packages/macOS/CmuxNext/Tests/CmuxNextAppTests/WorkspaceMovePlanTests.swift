@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSidebar
import Testing

/// Sidebar reorders reach the daemon as commands whose indexes follow
/// cmux-tui's rules (cmux-tui/spec/commands.md): `move-workspace` takes an
/// insertion index counted with the moved workspace still in place, and
/// `move-workspace-to-group` a final index among the destination's other
/// members. `Daemon` applies them exactly as cmux-tui does, so each test
/// checks where the rows really end up, not which number was sent.
struct WorkspaceMovePlanTests {
    typealias Entry = WorkspaceMovePlan.Entry

    /// cmux-tui's workspace order, with its two reorder commands.
    struct Daemon {
        var order: [Entry]

        mutating func apply(_ command: WorkspaceMovePlan.Command) {
            switch command {
            case let .move(id, index):
                // `move-workspace`: `index` is an insertion point with the
                // source still in place, so moving right lands one before it
                // (mux.rs move_workspace_right_uses_insertion_index).
                guard let from = order.firstIndex(where: { $0.id == id }) else { return }
                let entry = order.remove(at: from)
                order.insert(entry, at: min(index > from ? index - 1 : index, order.count))
            case let .place(id, group, index):
                // `move-workspace-to-group` (presentation.rs move_workspace_to_group).
                guard let old = order.firstIndex(where: { $0.id == id }) else { return }
                let remaining = order.indices.filter { $0 != old }
                let members = remaining.filter { order[$0].group == group }
                let position = { (target: Int) in remaining.firstIndex(of: target) ?? old }
                var new = old
                if let last = members.last {
                    new = index < members.count ? position(members[index]) : position(last) + 1
                }
                new = min(new, order.count - 1)
                var entry = order.remove(at: old)
                entry.group = group
                order.insert(entry, at: new)
            }
        }

        func ids(in group: String?) -> [String] { order.filter { $0.group == group }.map(\.id) }
    }

    static let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)

    static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: SidebarWorkspaceID(id), title: id) }

    /// The window's sidebar: ungrouped rows first, then groups, as the daemon lists them.
    static func window(_ ungrouped: [String], groups: [(String, [String])] = []) -> [SidebarRowSection] {
        let nodes = ungrouped.map { SidebarNode.workspace(row($0)) }
            + groups.map { SidebarNode.group(SidebarGroup(id: GroupID($0.0), name: $0.0, workspaces: $0.1.map(row))) }
        return [SidebarRowSection(kind: .machine(machine), nodes: nodes)]
    }

    static func drop(_ moving: [String], index: Int, group: String? = nil, window: [SidebarRowSection], daemon: [Entry],
                     groupOrder: [String] = []) -> Daemon {
        var simulated = Daemon(order: daemon)
        let position = DropPosition(section: .machine(.local), group: group.map(GroupID.init), index: index)
        let commands = WorkspaceMovePlan.commands(for: position, moving: moving.map(SidebarWorkspaceID.init), window: window,
                                                  daemon: daemon, groupOrder: groupOrder) ?? []
        for command in commands { simulated.apply(command) }
        return simulated
    }

    static func plain(_ ids: [String]) -> [Entry] { ids.map { Entry(id: $0) } }

    @Test func dropBelowTheLastRowPutsTheWorkspaceLast() {
        let result = Self.drop(["a"], index: 2, window: Self.window(["a", "b", "c"]), daemon: Self.plain(["a", "b", "c"]))
        #expect(result.ids(in: nil) == ["b", "c", "a"])
    }

    @Test func dropBelowTheOtherRowOfTwoSwapsThem() {
        let result = Self.drop(["a"], index: 1, window: Self.window(["a", "b"]), daemon: Self.plain(["a", "b"]))
        #expect(result.ids(in: nil) == ["b", "a"])
    }

    @Test func dropAboveTheFirstRowPutsTheWorkspaceFirst() {
        let result = Self.drop(["c"], index: 0, window: Self.window(["a", "b", "c"]), daemon: Self.plain(["a", "b", "c"]))
        #expect(result.ids(in: nil) == ["c", "a", "b"])
    }

    @Test func movingRightByOneLandsBetweenTheNeighbors() {
        let result = Self.drop(["a"], index: 1, window: Self.window(["a", "b", "c"]), daemon: Self.plain(["a", "b", "c"]))
        #expect(result.ids(in: nil) == ["b", "a", "c"])
    }

    @Test func severalWorkspacesDroppedAtTheEndKeepTheirOrder() {
        let result = Self.drop(["a", "b"], index: 2, window: Self.window(["a", "b", "c", "d"]), daemon: Self.plain(["a", "b", "c", "d"]))
        #expect(result.ids(in: nil) == ["c", "d", "a", "b"])
    }

    /// The window lists only its own workspaces; the others keep their slots.
    @Test func endOfAWindowThatListsOnlySomeWorkspacesFollowsItsLastRow() {
        let result = Self.drop(["a"], index: 1, window: Self.window(["a", "c"]), daemon: Self.plain(["a", "b", "c", "d"]))
        #expect(result.ids(in: nil) == ["b", "c", "a", "d"])
    }

    @Test func dropAtTheEndOfAGroupJoinsItLast() {
        let daemon = [Entry(id: "a"), Entry(id: "x", group: "g"), Entry(id: "y", group: "g")]
        let result = Self.drop(["a"], index: 2, group: "g", window: Self.window(["a"], groups: [("g", ["x", "y"])]),
                               daemon: daemon, groupOrder: ["g"])
        #expect(result.ids(in: "g") == ["x", "y", "a"])
        #expect(result.ids(in: nil).isEmpty)
    }

    @Test func dropInsideAGroupLandsBetweenItsMembers() {
        let daemon = [Entry(id: "a"), Entry(id: "b"), Entry(id: "x", group: "g"), Entry(id: "y", group: "g")]
        let result = Self.drop(["a"], index: 1, group: "g", window: Self.window(["a", "b"], groups: [("g", ["x", "y"])]),
                               daemon: daemon, groupOrder: ["g"])
        #expect(result.ids(in: "g") == ["x", "a", "y"])
    }

    /// Groups interleave with ungrouped workspaces in the durable order; the
    /// sidebar still lists ungrouped rows first.
    @Test func endOfTheUngroupedRowsFollowsTheLastUngroupedRowInTheDurableOrder() {
        let daemon = [Entry(id: "x", group: "g"), Entry(id: "a"), Entry(id: "y", group: "g"), Entry(id: "b")]
        let result = Self.drop(["a"], index: 1, window: Self.window(["a", "b"], groups: [("g", ["x", "y"])]),
                               daemon: daemon, groupOrder: ["g"])
        #expect(result.ids(in: nil) == ["b", "a"])
        #expect(result.ids(in: "g") == ["x", "y"])
    }

    @Test func draggingAGroupedWorkspaceOutUngroupsItAtTheDropSlot() {
        let daemon = [Entry(id: "a"), Entry(id: "b"), Entry(id: "x", group: "g"), Entry(id: "y", group: "g")]
        let result = Self.drop(["x"], index: 2, window: Self.window(["a", "b"], groups: [("g", ["x", "y"])]),
                               daemon: daemon, groupOrder: ["g"])
        #expect(result.ids(in: nil) == ["a", "b", "x"])
        #expect(result.ids(in: "g") == ["y"])
    }
}
