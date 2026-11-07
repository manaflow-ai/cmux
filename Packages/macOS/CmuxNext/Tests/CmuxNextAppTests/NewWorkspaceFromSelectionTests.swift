import CmuxNextBridge
import CmuxNextSettings
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-06: "you create a workspace, like, while selecting a current workspace. It just makes one right
/// under it. Okay, fine. But then it's, like, what is this? Then you create one inside a group, and then it sends
/// it down? Sometimes, for some reason? ... there should just be one behavior". One rule for every path: right
/// below the selected workspace, in its group; from a group's own + with nothing of it selected, at that group's
/// end; and when the selected one closes while the new one is made, where it was, never the sidebar's end.
@Suite struct NewWorkspaceFromSelectionTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let section = SectionID.machine(.local)
    static let g1 = GroupID("g1")

    static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    /// Loose `a`; group `g1` (`c`, `d`, `e`); loose `f`, less `closed`; the new workspace `n` last, where the daemon
    /// lists it.
    static func sections(without closed: String? = nil, new: Bool = true) -> [SidebarSection] {
        let keep = { (id: String) in id != closed }
        let members = ["c", "d", "e"].filter(keep).map(row)
        return [SidebarSection(kind: .machine(machine), nodes: ["a"].filter(keep).map { .workspace(row($0)) } + [
            .group(SidebarGroup(id: g1, name: "one", workspaces: members)),
        ] + ["f"].filter(keep).map { .workspace(row($0)) } + (new ? [.workspace(row("n"))] : []))]
    }

    /// The rule a press made from `current` takes: the rows as they were then (no `n` yet).
    static func rule(from current: String?) -> NewWorkspaceDefaultSlot {
        NewWorkspaceDefaultSlot(placement: .afterCurrent, current: current,
                                currentGaps: NewWorkspaceDefaultSlot.gaps(around: current, in: sections(new: false)))
    }

    /// The loose rows and `g1`'s members once `n` is at `slot`, resolved against the rows once the daemon lists `n`.
    static func apply(_ slot: WorkspaceSlot?, closing closed: String? = nil) throws -> (loose: [String], group: [String]) {
        var sections = sections(without: closed)
        let slot = try #require(slot, "keeps the daemon's place, the sidebar's end")
        let position = try #require(slot.position(moving: ["n"], section: section, in: sections), "\(slot) does not resolve")
        // False when `n` already lists there (a no-op reorder): the order below says where it is.
        _ = SidebarEdits.apply(.reorder([WorkspaceID("n")], to: position), to: &sections)
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

    static func fromSelection(_ current: String?, closing closed: String? = nil) throws -> (loose: [String], group: [String]) {
        try apply(rule(from: current).slot(for: "n", section: section, in: sections(without: closed), home: nil), closing: closed)
    }

    static func fromGroupPlus(_ current: String?, closing closed: String? = nil) throws -> [String] {
        let members = ["c", "d", "e"]
        return try apply(rule(from: current).slot(inGroup: g1, members: members), closing: closed).group
    }

    @Test func selectedInAGroupGoesRightBelowItInThatGroup() throws {
        let placed = try Self.fromSelection("d")
        #expect(placed.group == ["c", "d", "n", "e"])
        #expect(placed.loose == ["a", "f"])
        #expect(try Self.fromSelection("e").group == ["c", "d", "e", "n"])
    }

    @Test func selectedUngroupedGoesRightBelowItOutsideEveryGroup() throws {
        let placed = try Self.fromSelection("a")
        #expect(placed.loose == ["a", "n", "f"])
        #expect(placed.group == ["c", "d", "e"])
        #expect(try Self.fromSelection("f").loose == ["a", "f", "n"])
    }

    @Test func aGroupsPlusWithNothingOfItSelectedGoesToTheGroupsEnd() throws {
        for current in ["a", "f", nil] {
            #expect(try Self.fromGroupPlus(current) == ["c", "d", "e", "n"], "from \(current ?? "none")")
        }
        // With one of its members selected: right below that one.
        #expect(try Self.fromGroupPlus("c") == ["c", "n", "d", "e"])
    }

    @Test func theSelectedOneClosingMidCreateLeavesTheNewOneInItsPlace() throws {
        // `d` closes before `n` is listed: `n` takes `d`'s place, still in the group.
        #expect(try Self.fromSelection("d", closing: "d").group == ["c", "n", "e"])
        #expect(try Self.fromGroupPlus("d", closing: "d") == ["c", "n", "e"])
        // The group's last member: the group's end.
        #expect(try Self.fromSelection("e", closing: "e").group == ["c", "d", "n"])
        #expect(try Self.fromGroupPlus("e", closing: "e") == ["c", "d", "n"])
        // A loose one: where it was, not the top or the end.
        let loose = try Self.fromSelection("a", closing: "a")
        #expect(loose.loose == ["n", "f"])
        let last = try Self.fromSelection("f", closing: "f")
        #expect(last.loose == ["a", "n"])
    }
}
