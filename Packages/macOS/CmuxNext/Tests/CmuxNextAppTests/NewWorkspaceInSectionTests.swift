@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSettings
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-22: "OH YEAH LAWRENCE WANTED DEFAULT NEW WORKSPACE AT THE TOP". New Workspace in Section on the
/// workspace list places by `workspaces.newPlacement` as if the window showed no workspace
/// (`WorkspaceSpawn.placesFromCurrent`): under the default `top` first in the section, below Home, even while the
/// window shows a workspace in a group; under `bottom` where the daemon puts it (the end of the loose rows).
@Suite struct NewWorkspaceInSectionTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let g1 = GroupID("g1")

    static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    /// Optional Home; loose `a`; group `g1` (`c`, `d`, `e`); loose `f`; the new workspace `n` where the daemon lists it, last.
    static func sections(home: Bool) -> [SidebarSection] {
        [SidebarSection(kind: .machine(machine), nodes: (home ? [.workspace(row("home"))] : []) + [
            .workspace(row("a")),
            .group(SidebarGroup(id: g1, name: "one", workspaces: [row("c"), row("d"), row("e")])),
            .workspace(row("f")),
            .workspace(row("n")),
        ])]
    }

    /// The section's loose rows and `g1`'s members after placing `n` by the section rule (no current workspace).
    static func placed(_ placement: NewWorkspacePlacement, home: Bool) throws -> (loose: [String], group: [String])? {
        var sections = sections(home: home)
        let rule = NewWorkspaceDefaultSlot(placement: placement, current: nil)
        guard let slot = rule.slot(for: "n", section: .machine(.local), in: sections, home: home ? "home" : nil) else { return nil }
        // The daemon's create already put it at the section's top: the app sends no second move for it.
        #expect(rule.move(for: "n", section: .machine(.local), in: sections, home: home ? "home" : nil) == nil)
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

    @Test func topPutsItFirstInTheSectionNotInTheCurrentGroup() throws {
        let placed = try #require(try Self.placed(.top, home: false))
        #expect(placed.loose == ["n", "a", "f"])
        #expect(placed.group == ["c", "d", "e"])
    }

    @Test func topKeepsHomeFirst() throws {
        let placed = try #require(try Self.placed(.top, home: true))
        #expect(placed.loose == ["home", "n", "a", "f"])
        #expect(placed.group == ["c", "d", "e"])
    }

    @Test func bottomKeepsTheDaemonsPlaceAtTheEnd() throws {
        #expect(try Self.placed(.bottom, home: false) == nil)
    }

    /// The fallback Leo named: with no setting a new workspace goes to the top.
    @Test func theDefaultIsTop() {
        #expect(CmuxConfigSnapshot.newWorkspacePlacementFallback == .top)
    }
}
