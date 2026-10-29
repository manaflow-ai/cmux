@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSettings
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-20: "New" inside a group does not keep the new workspace in that group, right
/// below the one it was made from. Cmd-N, the sidebar's +, the palette, agent open and open session
/// place by `workspaces.newPlacement` (`NewWorkspaceDefaultSlot`); New Workspace Below and Duplicate
/// pass `.below(current)` themselves. With the default `top`, a new workspace made from `d` in group
/// `g1` (`c`, `d`, `e`) went to the top of the group, above `c`; it belongs right below `d`.
/// Lawrence 2026-10-28: a new workspace made inside a group goes to the TOP of that group by
/// default, like a new workspace goes to the top of the sidebar; `afterCurrent` ("After Current
/// Workspace" in Settings) keeps Leo's place right below the current one.
@Suite struct NewWorkspaceInGroupTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let g1 = GroupID("g1")

    static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    /// Loose `a`; group `g1` (`c`, `d`, `e`); loose `f`; the new workspace `n` where the daemon lists it, last.
    static func sections() -> [SidebarSection] {
        [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(row("a")),
            .group(SidebarGroup(id: g1, name: "one", workspaces: [row("c"), row("d"), row("e")])),
            .workspace(row("f")),
            .workspace(row("n")),
        ])]
    }

    /// The section's loose rows and `g1`'s members after placing `n` by `placement`, made from `current`.
    static func placed(_ placement: NewWorkspacePlacement, from current: String) throws -> (loose: [String], group: [String]) {
        var sections = sections()
        let rule = NewWorkspaceDefaultSlot(placement: placement, current: current)
        let slot = try #require(rule.slot(for: "n", section: .machine(.local), in: sections, home: nil), "\(placement) from \(current) keeps the daemon's place")
        let position = try #require(slot.position(moving: ["n"], section: .machine(.local), in: sections))
        #expect(SidebarEdits.apply(.reorder([WorkspaceID("n")], to: position), to: &sections))
        var loose: [String] = [], group: [String] = []
        for node in sections[0].nodes {
            switch node {
            case let .workspace(workspace): loose.append(workspace.id.rawValue)
            case let .group(listed): group = listed.workspaces.map(\.id.rawValue)
            case .item: break
            }
        }
        return (loose, group)
    }

    @Test func topFromAGroupMemberGoesToTheTopOfThatGroup() throws {
        for current in ["c", "d", "e"] {
            let placed = try Self.placed(.top, from: current)
            #expect(placed.group == ["n", "c", "d", "e"], "top from \(current)")
            #expect(placed.loose == ["a", "f"], "top from \(current)")
        }
    }

    @Test func theDefaultPlacementPutsANewWorkspaceFirstInItsGroup() throws {
        let placed = try Self.placed(CmuxConfigSnapshot.newWorkspacePlacementFallback, from: "d")
        #expect(placed.group == ["n", "c", "d", "e"])
    }

    @Test func afterCurrentFromAGroupMemberGoesRightBelowItInThatGroup() throws {
        let placed = try Self.placed(.afterCurrent, from: "d")
        #expect(placed.group == ["c", "d", "n", "e"])
        #expect(placed.loose == ["a", "f"])
    }

    @Test func afterCurrentFromTheGroupsLastMemberStaysInTheGroup() throws {
        let placed = try Self.placed(.afterCurrent, from: "e")
        #expect(placed.group == ["c", "d", "e", "n"])
    }

    @Test func newFromALooseWorkspaceStillGoesToTheTop() throws {
        let placed = try Self.placed(.top, from: "f")
        #expect(placed.loose == ["n", "a", "f"])
        #expect(placed.group == ["c", "d", "e"])
    }

    @Test func bottomFromAGroupMemberIsTheGroupsLastSlot() throws {
        let placed = try Self.placed(.bottom, from: "c")
        #expect(placed.group == ["c", "d", "e", "n"])
    }
}
