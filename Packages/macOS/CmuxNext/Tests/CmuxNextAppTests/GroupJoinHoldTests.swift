@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-03: "i hate it when you guys make new worksapces or whatever and they appear for a split second and
/// it's just bloop and then it goes into presumably whichever group... it's just weird how it flickers into some top
/// level group or whatever then goes away". A workspace `acpmux new --group` opens lists loose in the daemon's
/// create, then joins its group a hop later. Every pass the sidebar draws shows it in its group or not at all.
@Suite struct GroupJoinHoldTests {
    static let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let other = SidebarMachine(id: MachineID("big-red"), name: "big-red", kind: .ssh)

    static func row(_ id: String, on machine: MachineID = .local) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), machineID: machine, title: id)
    }

    /// The daemon's create: `n` lists loose above the group.
    static let created = [SidebarSection(kind: .machine(local), nodes: [
        .workspace(row("n")),
        .group(SidebarGroup(id: GroupID("g"), name: "lanes", workspaces: [row("a")])),
        .workspace(row("b")),
    ])]
    /// The join landed: `n` lists in `g`.
    static let joined = [SidebarSection(kind: .machine(local), nodes: [
        .group(SidebarGroup(id: GroupID("g"), name: "lanes", workspaces: [row("a"), row("n")])),
        .workspace(row("b")),
    ])]

    /// The ids a pass draws outside any group.
    static func loose(_ sections: [SidebarSection]) -> [String] {
        sections.flatMap(\.nodes).compactMap { node in
            if case let .workspace(workspace) = node { return workspace.id.rawValue }
            return nil
        }
    }

    @Test func aGroupedCreateNeverDrawsLoose() {
        var hold = GroupJoinHold()
        hold.hold("n")
        let start = ContinuousClock.now
        var drawn: [[SidebarSection]] = []
        // Every pass the bridge produces, the create's and the join's, with a few passes between them.
        for (offset, sections) in [(0, Self.created), (50, Self.created), (300, Self.created), (400, Self.joined), (500, Self.joined)] {
            let hidden = hold.hiding(in: sections, now: start + .milliseconds(offset))
            drawn.append(SidebarEdits.removing(hidden, from: sections))
        }
        for pass in drawn { #expect(!Self.loose(pass).contains("n"), "n drew loose before its group") }
        #expect(drawn.suffix(2).allSatisfy { SidebarEdits.workspace(WorkspaceID("n"), in: $0) != nil }, "n draws in its group")
        #expect(Self.loose(drawn[0]) == ["b"], "no other row is left out")
        #expect(hold.isEmpty, "listing in its group releases it")
    }

    @Test func aJoinThatNeverLandsShowsTheRowOnceTheLimitPasses() {
        var hold = GroupJoinHold()
        hold.hold("n")
        let start = ContinuousClock.now
        #expect(hold.hiding(in: Self.created, now: start) == ["n"])
        #expect(hold.hiding(in: Self.created, now: start + GroupJoinHold.limit - .milliseconds(1)) == ["n"])
        // The limit counts from the first loose pass, not from the hold: a slow create still gets the full window.
        #expect(hold.hiding(in: Self.created, now: start + GroupJoinHold.limit).isEmpty)
        #expect(hold.isEmpty)
    }

    @Test func aSlowCreateIsHeldFromItsFirstListing() {
        var hold = GroupJoinHold()
        hold.hold("n")
        let start = ContinuousClock.now
        #expect(hold.hiding(in: Self.joined.map { var s = $0; s.nodes.removeFirst(); return s }, now: start).isEmpty)
        #expect(hold.hiding(in: Self.created, now: start + .seconds(5)) == ["n"], "not listed yet: no time spent")
    }

    @Test func aReleasedCreateIsNotHeld() {
        var hold = GroupJoinHold()
        hold.hold("n")
        hold.release("n")
        #expect(hold.hiding(in: Self.created, now: .now).isEmpty)
    }

    /// The join reads the window's rows, which leave the held row out: the named group takes it by its machine.
    @Test func theNamedGroupTakesAHeldRowByItsMachine() {
        let sections = [
            SidebarSection(kind: .machine(Self.other), nodes: [
                .group(SidebarGroup(id: GroupID("remote"), name: "lanes", workspaces: [Self.row("r", on: MachineID("big-red"))])),
            ]),
            SidebarSection(kind: .machine(Self.local), nodes: [
                .group(SidebarGroup(id: GroupID("g"), name: "lanes", workspaces: [Self.row("a")])),
            ]),
        ]
        #expect(SidebarEdits.group(named: "lanes", accepting: WorkspaceID("n"), in: sections) == nil, "unlisted, no machine: none")
        #expect(SidebarEdits.group(named: "lanes", accepting: WorkspaceID("n"), in: sections, machine: .local) == GroupID("g"))
        #expect(SidebarEdits.group(named: "lanes", accepting: WorkspaceID("n"), in: sections, machine: MachineID("big-red")) == GroupID("remote"))
    }
}
